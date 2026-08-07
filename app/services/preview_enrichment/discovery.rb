module PreviewEnrichment
  class Discovery
    PROVIDERS = [
      Providers::ExistingLink,
      Providers::SourcePageImage,
      Providers::MakerworldSearch,
      Providers::ThingiverseSearch
    ].freeze

    def initialize(model)
      @model = model
    end

    def call
      eligibility = Eligibility.new(model)

      return [] unless eligibility.eligible?

      PROVIDERS.flat_map do |provider_class|
        provider_class.new(model).search
      rescue StandardError => error
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
