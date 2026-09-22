class LibraryIngestion::VerifyReadyJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 20
  RETRY_DELAY = 15.seconds

  def perform(ingest_id, attempt = 0)
    ingest = LibraryIngest.find(ingest_id)

    return if ingest.processing_status == "ready"
    return unless ingest.processing_status == "rendering"

    model = find_model(ingest)

    unless model
      return retry_or_fail!(
        ingest,
        attempt,
        "Model disappeared during preview processing"
      )
    end

    renderable =
      model.model_files.select do |file|
        file.is_3d_model? &&
          PreviewRendering::EnsureRenderJob::
            RENDERABLE_EXTENSIONS.include?(
              file.extension.to_s.downcase
            )
      end

    missing =
      renderable.reject do |file|
        render_available?(file)
      end

    if missing.empty?
      ingest.update!(
        processing_status: "ready",
        ready_at: Time.current,
        processing_error: nil
      )

      return
    end

    retry_or_fail!(
      ingest,
      attempt,
      "#{missing.length} preview render(s) still unavailable"
    )
  rescue => error
    ingest&.update_columns(
      processing_status: "failed",
      processing_error:
        "#{error.class}: #{error.message}".truncate(4000),
      updated_at: Time.current
    )
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

  def render_available?(file)
    return false unless file.has_render?

    render_path =
      file.path_within_library(
        derivative: :render
      )

    file.model.library.has_file?(
      render_path
    )
  rescue
    false
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
end
