class LibraryIngestion::UploadTracker
  VERIFY_DELAY = 15.seconds

  def self.record(model:, file:, tus_upload:)
    new(
      model: model,
      file: file,
      tus_upload: tus_upload
    ).record
  end

  def initialize(model:, file:, tus_upload:)
    @model = model
    @file = file
    @tus_upload = tus_upload
  end

  def record
    ingest =
      LibraryIngest.find_or_initialize_by(
        library: @model.library,
        source_path: source_key
      )

    ingest.assign_attributes(
      model: @model,
      model_file: @file,
      source_name: @file.filename,
      source_type: "upload",
      source_origin: "ui_upload",
      source_size: safe_size,
      status: "completed",
      destination_path:
        File.join(
          @model.library.path,
          @model.path
        ),
      started_at: Time.current,
      completed_at: Time.current,
      error_message: nil,
      processing_status:
        renderable? ? "rendering" : "ready",
      processing_started_at: Time.current,
      ready_at:
        renderable? ? nil : Time.current,
      render_jobs_count:
        renderable? ? 1 : 0,
      processing_error: nil
    )

    ingest.save!

    if renderable?
      LibraryIngestion::VerifyReadyJob
        .set(wait: VERIFY_DELAY)
        .perform_later(
          ingest.id,
          0
        )
    end

    ingest
  rescue => error
    Rails.logger.error(
      "UI upload ingestion tracking failed " \
      "model_id=#{@model&.id} " \
      "file_id=#{@file&.id} " \
      "error=#{error.class}: #{error.message}"
    )

    nil
  end

  private

  def source_key
    upload_id =
      @tus_upload[:id].to_s

    "upload:#{upload_id}"
  end

  def safe_size
    @file.size
  rescue
    nil
  end

  def renderable?
    @file.is_3d_model? &&
      PreviewRendering::EnsureRenderJob::
        RENDERABLE_EXTENSIONS.include?(
          @file.extension.to_s.downcase
        )
  end
end
