# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/cloud-api/reference/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  DOWNLOAD_ATTEMPTS = 3
  DOWNLOAD_OPEN_TIMEOUT = 20
  DOWNLOAD_READ_TIMEOUT = 60

  private

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  def handle_media_download_failure(attachment_payload)
    media_id = attachment_payload[:id].presence || attachment_payload['id'].presence
    return if media_id.blank?

    @message.content_attributes = @message.content_attributes.merge(
      'pending_whatsapp_media' => {
        'id' => media_id.to_s,
        'mime_type' => attachment_payload[:mime_type] || attachment_payload['mime_type'],
        'filename' => attachment_payload[:filename] || attachment_payload['filename'],
        'message_type' => message_type
      }
    )
  end

  def after_message_created
    pending = @message.content_attributes['pending_whatsapp_media']
    return if pending.blank?
    return if @message.attachments.exists?

    Whatsapp::RetryMediaDownloadJob.set(wait: 30.seconds).perform_later(@message.id)
  end

  def download_attachment_file(attachment_payload)
    media_id = attachment_payload[:id].presence || attachment_payload['id'].presence
    webhook_url = attachment_payload[:url].presence || attachment_payload['url'].presence
    filename = attachment_payload[:filename].presence || attachment_payload['filename'].presence
    last_error = nil

    DOWNLOAD_ATTEMPTS.times do |attempt|
      media_url = resolve_media_download_url(media_id, webhook_url: webhook_url, attempt: attempt)
      next if media_url.blank?

      downloaded_file = download_from_url(media_url)
      downloaded_file.define_singleton_method(:original_filename) { filename } if filename.present?
      return downloaded_file
    rescue Down::Error, Down::ClientError, IOError => e
      last_error = e
      Rails.logger.warn(
        "[WhatsApp] media download attempt=#{attempt + 1}/#{DOWNLOAD_ATTEMPTS} " \
        "inbox=#{inbox.id} media_id=#{media_id} error=#{e.class}: #{e.message}"
      )
      sleep(0.5 * (attempt + 1)) if attempt < DOWNLOAD_ATTEMPTS - 1
    end

    Rails.logger.warn(
      "[WhatsApp] media download failed inbox=#{inbox.id} media_id=#{media_id} " \
      "error=#{last_error&.class}: #{last_error&.message}"
    )
    nil
  end

  def resolve_media_download_url(media_id, webhook_url:, attempt:)
    return if media_id.blank?

    url_response = HTTParty.get(
      inbox.channel.media_url(media_id),
      headers: inbox.channel.api_headers,
      timeout: DOWNLOAD_OPEN_TIMEOUT
    )

    # This url response will be failure if the access token has expired.
    # Only count once per webhook — retries would otherwise inflate the reauth threshold.
    inbox.channel.authorization_error! if attempt.zero? && url_response.unauthorized?
    return url_response.parsed_response['url'] if url_response.success?

    # Webhook CDN URLs expire in ~5 minutes — only use on the first attempt.
    if attempt.zero? && webhook_url.present?
      Rails.logger.warn(
        "[WhatsApp] Graph media lookup failed (#{url_response.code}); " \
        "using webhook URL for media_id=#{media_id}"
      )
      return webhook_url
    end

    Rails.logger.warn(
      "[WhatsApp] media lookup failed inbox=#{inbox.id} code=#{url_response.code} " \
      "media_id=#{media_id} body=#{url_response.body.to_s.first(200)}"
    )
    nil
  end

  def download_from_url(media_url)
    # CDN download needs the bearer token; Content-Type: application/json is unnecessary and can confuse some paths.
    Down.download(
      media_url,
      headers: media_download_headers,
      open_timeout: DOWNLOAD_OPEN_TIMEOUT,
      read_timeout: DOWNLOAD_READ_TIMEOUT
    )
  end

  def media_download_headers
    token = inbox.channel.provider_config['api_key']
    { 'Authorization' => "Bearer #{token}" }
  end
end
