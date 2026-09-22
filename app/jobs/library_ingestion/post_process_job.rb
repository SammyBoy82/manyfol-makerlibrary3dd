class LibraryIngestion::PostProcessJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 12
  RETRY_DELAY = 15.seconds

  def perform(ingest_id, attempt = 0)
    ingest = LibraryIngest.find(ingest_id)

    return unless ingest.completed?
    return if ingest.processing_status == "ready"

    ingest.update!(
      processing_status: "scanning",
      processing_started_at:
        ingest.processing_started_at || Time.current,
      processing_error: nil
    )

    model = find_model(ingest)

    unless model
      return retry_or_fail!(
        ingest,
        attempt,
        "Waiting for Manyfold filesystem scan to create model"
      )
    end

    model_files =
      model.model_files.reload.to_a

    if model_files.empty?
      return retry_or_fail!(
        ingest,
        attempt,
        "Waiting for Manyfold to discover model files"
      )
    end

    model.parse_metadata_later

    renderable =
      model_files.select do |file|
        file.is_3d_model? &&
          PreviewRendering::EnsureRenderJob::
            RENDERABLE_EXTENSIONS.include?(
              file.extension.to_s.downcase
            )
      end

    renderable.each do |file|
      file.parse_metadata_later

      PreviewRendering::EnsureRenderJob
        .perform_later(file.id)
    end

    if renderable.empty?
      ingest.update!(
        processing_status: "ready",
        render_jobs_count: 0,
        ready_at: Time.current,
        processing_error: nil
      )

      return
    end

    ingest.update!(
      processing_status: "rendering",
      render_jobs_count: renderable.length,
      processing_error: nil
    )

    LibraryIngestion::VerifyReadyJob
      .set(wait: RETRY_DELAY)
      .perform_later(
        ingest.id,
        0
      )
  rescue => error
    mark_failed(ingest, error)
  end

  private

  def find_model(ingest)
    relative =
      Pathname.new(ingest.destination_path)
        .relative_path_from(
          Pathname.new(ingest.library.path)
        )
        .to_s
        .trim_path_separators

    ingest.library.models.find_by(
      path: relative
    )
  rescue ArgumentError
    nil
  end

  def retry_or_fail!(ingest, attempt, message)
    if attempt < MAX_ATTEMPTS
      self.class
        .set(wait: RETRY_DELAY)
        .perform_later(
          ingest.id,
          attempt + 1
        )
    else
      ingest.update!(
        processing_status: "failed",
        processing_error: message
      )
    end
  end

  def mark_failed(ingest, error)
    ingest&.update_columns(
      processing_status: "failed",
      processing_error:
        "#{error.class}: #{error.message}".truncate(4000),
      updated_at: Time.current
    )

    Rails.logger.error(
      "Post-ingest processing failed " \
      "ingest_id=#{ingest&.id} " \
      "error=#{error.class}: #{error.message}"
    )
  rescue => logging_error
    Rails.logger.error(
      "Unable to record post-ingest failure: " \
      "#{logging_error.class}: #{logging_error.message}"
    )
  end
end
