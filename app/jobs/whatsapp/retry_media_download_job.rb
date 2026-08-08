# Retries WhatsApp Cloud media downloads that failed during webhook processing.
# Media IDs from webhooks remain valid for ~7 days; CDN URLs only ~5 minutes,
# so each attempt re-resolves a fresh URL via Graph before downloading.
class Whatsapp::RetryMediaDownloadJob < ApplicationJob
  queue_as :low

  class DownloadFailed < StandardError; end

  # Polynomially longer waits cover transient lookaside.fbsbx.com resets.
  retry_on DownloadFailed, wait: :polynomially_longer, attempts: 8

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank?
    return if message.attachments.exists?

    pending = message.content_attributes['pending_whatsapp_media']
    return if pending.blank?

    channel = message.inbox.channel
    return unless channel.is_a?(Channel::Whatsapp)

    media_id = pending['id'].presence
    return if media_id.blank?

    downloaded_file = download_media(channel, media_id, pending['filename'])
    raise DownloadFailed, "media_id=#{media_id}" if downloaded_file.blank?

    attach_file!(message, pending, downloaded_file)
    clear_pending!(message)
  end

  private

  def download_media(channel, media_id, filename)
    url_response = HTTParty.get(channel.media_url(media_id), headers: channel.api_headers, timeout: 20)
    channel.authorization_error! if url_response.unauthorized?
    media_url = url_response.parsed_response['url'] if url_response.success?
    return if media_url.blank?

    token = channel.provider_config['api_key']
    downloaded_file = Down.download(
      media_url,
      headers: { 'Authorization' => "Bearer #{token}" },
      open_timeout: 20,
      read_timeout: 60
    )
    downloaded_file.define_singleton_method(:original_filename) { filename } if filename.present?
    downloaded_file
  rescue Down::Error, Down::ClientError, IOError => e
    Rails.logger.warn(
      "[WhatsApp] RetryMediaDownloadJob media_id=#{media_id} error=#{e.class}: #{e.message}"
    )
    nil
  end

  def attach_file!(message, pending, downloaded_file)
    file_type = pending['message_type'].presence || 'document'
    message.attachments.create!(
      account_id: message.account_id,
      file_type: mapped_file_type(file_type),
      file: {
        io: downloaded_file,
        filename: downloaded_file.original_filename,
        content_type: downloaded_file.content_type
      }
    )
  end

  def clear_pending!(message)
    attrs = message.content_attributes.except('pending_whatsapp_media')
    updates = { content_attributes: attrs }

    failed = I18n.t('conversations.messages.whatsapp.media_download_failed')
    failed_echo = I18n.t('conversations.messages.whatsapp.media_download_failed_echo')
    if [failed, failed_echo].include?(message.content)
      updates[:content] = nil
      updates[:processed_message_content] = nil
    end

    message.update!(updates)
  end

  def mapped_file_type(file_type)
    return :image if %w[image sticker].include?(file_type)
    return :audio if %w[audio voice].include?(file_type)
    return :video if file_type == 'video'

    :file
  end
end
