module PreviewEnrichment
  class InventoryJob < ApplicationJob
    queue_as :default

    def perform(model_id)
      model = Model.find_by(id: model_id)
      return unless model

      eligibility = Eligibility.new(model)

      Rails.logger.info(
        {
          event: "preview_enrichment_inventory",
          model_id: model.id,
          model_name: model.name,
          eligible: eligibility.eligible?,
          reason: eligibility.reason
        }.to_json
      )

      return unless eligibility.eligible?

      query_data = QueryBuilder.new(model)

      Rails.logger.info(
        {
          event: "preview_enrichment_required",
          model_id: model.id,
          queries: query_data.queries,
          evidence: query_data.evidence
        }.to_json
      )
    end
  end
end
