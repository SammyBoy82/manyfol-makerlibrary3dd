module PreviewEnrichment
  class Discovery
    PROVIDERS = [
      Providers::ExistingLink
    ].freeze

    def initialize(model)
      @model = model
    end

    def call
      return [] unless Eligibility.new(model).eligible?

      PROVIDERS.flat_map do |provider_class|
        provider_class.new(model).search
      rescue => error
        Rails.logger.error(
          {
            event: "preview_enrichment_provider_failed",
            model_id: model.id,
            provider: provider_class.name,
            error: error.class.name,
            message: error.message
          }.to_json
        )

        []
      end
    end

    private

    attr_reader :model
  end
end
