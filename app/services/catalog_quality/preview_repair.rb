class CatalogQuality::PreviewRepair
  def initialize(model)
    @model = model
  end

  def call
    return :already_has_preview if @model.preview_file.present?

    @model.parse_metadata_later

    render_jobs = 0

    @model.model_files.each do |file|
      next unless PreviewRendering::EnsureRenderJob::RENDERABLE_EXTENSIONS.include?(
        file.extension.to_s.downcase
      )

      PreviewRendering::EnsureRenderJob.perform_later(file.id)
      render_jobs += 1
    end

    Scan::Model::ParseMetadataJob
      .set(wait: 30.seconds)
      .perform_later(@model.id)

    {
      status: :queued,
      render_jobs: render_jobs
    }
  end
end
