module Admin
  class CommercialReadiness
    Result = Struct.new(
      :model_id,
      :score,
      :member,
      :digital,
      :physical,
      :quote,
      :storefront,
      :core_checks,
      keyword_init: true
    )

    Channel = Struct.new(:enabled, :ready, :blockers, keyword_init: true)

    def self.call(model:, metadata: nil)
      new(model: model, metadata: metadata).call
    end

    def initialize(model:, metadata: nil)
      @model = model
      @metadata = metadata || ModelCommercialMetadata.find_by(model_id: model.id)
    end

    def call
      files = @model.model_files.to_a
      source_files = files.reject { |file| ModelFile::SPECIAL_FILES.include?(file.filename) }
      three_d_files = source_files.select(&:is_3d_model?)
      visual_files = source_files.select do |file|
        file.is_image? || file.is_video? || file.is_3d_model?
      end

      checks = {
        sku: @metadata&.sku.present?,
        source_file: source_files.any?,
        three_d_file: three_d_files.any?,
        visual: @model.preview_file_id.present? || visual_files.any?
      }

      member_enabled = @metadata.nil? || @metadata.member_download_enabled?
      digital_enabled = @metadata&.digital_sale_enabled? || false
      physical_enabled = @metadata&.physical_sale_enabled? || false
      quote_enabled = @metadata&.custom_quote_enabled? || false

      member = channel(
        enabled: member_enabled,
        requirements: {
          "No downloadable source files are registered." => checks[:source_file]
        }
      )

      digital = channel(
        enabled: digital_enabled,
        requirements: {
          "SKU is missing." => checks[:sku],
          "Digital price is missing." => @metadata&.digital_price_cents.present?,
          "No downloadable source files are registered." => checks[:source_file],
          "No usable catalogue preview/render source is available." => checks[:visual]
        }
      )

      physical = channel(
        enabled: physical_enabled,
        requirements: {
          "SKU is missing." => checks[:sku],
          "Physical from-price is missing." => @metadata&.physical_from_price_cents.present?,
          "Production lead time is missing." => @metadata&.lead_time_days.present?,
          "No 3D model file is registered." => checks[:three_d_file],
          "No usable catalogue preview/render source is available." => checks[:visual]
        }
      )

      quote = channel(
        enabled: quote_enabled,
        requirements: {
          "SKU is missing." => checks[:sku],
          "No usable catalogue preview/render source is available." => checks[:visual]
        }
      )

      enabled_sales = [digital, physical, quote].select(&:enabled)
      storefront_blockers = []
      storefront_blockers << "No commercial storefront channel is enabled." if enabled_sales.empty?
      storefront_blockers << "SKU is missing." unless checks[:sku]
      storefront_blockers << "No usable catalogue preview/render source is available." unless checks[:visual]
      storefront_blockers.concat(enabled_sales.flat_map(&:blockers)).uniq!

      storefront = Channel.new(
        enabled: enabled_sales.any?,
        ready: enabled_sales.any? && storefront_blockers.empty?,
        blockers: storefront_blockers
      )

      score_checks = [
        checks[:sku],
        checks[:source_file],
        checks[:visual],
        (!digital_enabled || digital.ready),
        (!physical_enabled || physical.ready),
        (!quote_enabled || quote.ready),
        (!member_enabled || member.ready)
      ]

      score = ((score_checks.count(true).to_f / score_checks.size) * 100).round

      Result.new(
        model_id: @model.id,
        score: score,
        member: member,
        digital: digital,
        physical: physical,
        quote: quote,
        storefront: storefront,
        core_checks: checks
      )
    end

    private

    def channel(enabled:, requirements:)
      blockers = requirements.filter_map { |message, passed| message unless passed }
      Channel.new(
        enabled: enabled,
        ready: enabled && blockers.empty?,
        blockers: blockers
      )
    end
  end
end
