class Admin::CatalogQualityController < ApplicationController
  before_action :require_administrator!

  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    analyzer =
      CatalogQuality::Analyzer.new

    scope =
      Model
        .includes(
          :library,
          :collections,
          :tags,
          :preview_file
        )

    @summary =
      analyzer.summary(scope)

    @results =
      scope
        .map { |model| analyzer.analyze(model) }
        .sort_by { |result| [result.score, result.model.name.to_s] }
        .first(200)

    render layout: "settings"
  end

  def repair_preview
    model = Model.find(params[:id])

    CatalogQuality::PreviewRepair
      .new(model)
      .call

    redirect_to admin_catalog_quality_path,
      notice: "Preview repair queued for #{model.name}."
  end

  def repair_all_previews
    CatalogQuality::RepairMissingPreviewsJob.perform_later

    redirect_to admin_catalog_quality_path,
      notice: "Missing preview repair queued."
  end

  private

  def require_administrator!
    raise Pundit::NotAuthorizedError unless current_user&.is_administrator?
  end
end
