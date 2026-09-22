class CatalogQuality::RepairMissingPreviewsJob < ApplicationJob
  queue_as :default
  unique :until_executed

  def perform
    Model
      .where(preview_file_id: nil)
      .find_each do |model|

      result =
        CatalogQuality::PreviewRepair
          .new(model)
          .call

      Rails.logger.info(
        "catalog_quality_preview_repair " \
        "model_id=#{model.id} " \
        "result=#{result.inspect}"
      )
    end
  end
end
