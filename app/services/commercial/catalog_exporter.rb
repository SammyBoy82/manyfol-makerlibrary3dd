module Commercial
  class CatalogExporter
    def self.call(base_url:)
      new(base_url: base_url).call
    end

    def initialize(base_url:)
      @base_url = base_url.to_s.sub(%r{/$}, "")
    end

    def call
      published = ModelCommercialMetadata
        .where(storefront_published: true)
        .includes(model: [:library, :model_files])
        .order(updated_at: :desc)

      items = published.filter_map do |metadata|
        model = metadata.model
        readiness = Admin::CommercialReadiness.call(model: model, metadata: metadata)
        next unless readiness.storefront.ready

        serialize(model, metadata, readiness)
      end

      {
        api_version: "v1",
        generated_at: Time.current.iso8601,
        count: items.size,
        items: items
      }
    end

    private

    def serialize(model, metadata, readiness)
      {
        id: model.id,
        public_id: model.public_id,
        slug: model.slug,
        name: model.name,
        sku: metadata.sku,
        library: {
          id: model.library_id,
          name: model.library&.name
        },
        featured: metadata.featured?,
        currency: metadata.currency,
        member_download_enabled: metadata.member_download_enabled?,
        channels: {
          digital: {
            enabled: metadata.digital_sale_enabled?,
            price_cents: metadata.digital_price_cents
          },
          physical: {
            enabled: metadata.physical_sale_enabled?,
            from_price_cents: metadata.physical_from_price_cents,
            lead_time_days: metadata.lead_time_days
          },
          custom_quote: {
            enabled: metadata.custom_quote_enabled?
          }
        },
        readiness: {
          score: readiness.score,
          storefront_ready: readiness.storefront.ready
        },
        preview_available: readiness.core_checks[:visual],
        model_url: "#{@base_url}/models/#{model.to_param}",
        updated_at: [model.updated_at, metadata.updated_at].compact.max&.iso8601
      }
    end
  end
end
