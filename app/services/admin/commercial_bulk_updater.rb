module Admin
  class CommercialBulkUpdater
    ALLOWED_ACTIONS = %w[
      member_on member_off
      digital_on digital_off
      physical_on physical_off
      quote_on quote_off
      featured_on featured_off
      publish_on publish_off
      set_digital_price
      set_physical_price
      set_lead_time
    ].freeze

    Result = Struct.new(:requested, :updated, :skipped, :errors, keyword_init: true)

    def self.call(model_ids:, action:, value: nil)
      new(model_ids: model_ids, action: action, value: value).call
    end

    def initialize(model_ids:, action:, value: nil)
      @model_ids = Array(model_ids).map(&:to_i).uniq.reject(&:zero?).first(250)
      @action = action.to_s
      @value = value
    end

    def call
      raise ArgumentError, "Select at least one model." if @model_ids.empty?
      raise ArgumentError, "Unknown bulk action." unless ALLOWED_ACTIONS.include?(@action)

      updated = 0
      skipped = 0
      errors = []

      Model.where(id: @model_ids).find_each do |model|
        begin
          metadata = ModelCommercialMetadata.find_or_initialize_by(model_id: model.id)
          attrs = attributes_for(metadata)

          if attrs.empty?
            skipped += 1
            next
          end

          metadata.update!(attrs)
          updated += 1
        rescue => error
          skipped += 1
          errors << {model_id: model.id, error: "#{error.class}: #{error.message}"}
        end
      end

      Result.new(
        requested: @model_ids.size,
        updated: updated,
        skipped: skipped,
        errors: errors.first(100)
      )
    end

    private

    def attributes_for(metadata)
      case @action
      when "member_on" then {member_download_enabled: true}
      when "member_off" then {member_download_enabled: false}
      when "digital_on"
        raise ArgumentError, "Set a digital price before enabling digital sale." if metadata.digital_price_cents.blank?
        {digital_sale_enabled: true}
      when "digital_off" then {digital_sale_enabled: false}
      when "physical_on"
        raise ArgumentError, "Set a physical from-price before enabling physical sale." if metadata.physical_from_price_cents.blank?
        {physical_sale_enabled: true}
      when "physical_off" then {physical_sale_enabled: false}
      when "quote_on" then {custom_quote_enabled: true}
      when "quote_off" then {custom_quote_enabled: false}
      when "featured_on" then {featured: true}
      when "featured_off" then {featured: false}
      when "publish_on" then {storefront_published: true}
      when "publish_off" then {storefront_published: false}
      when "set_digital_price" then {digital_price_cents: money_to_cents(@value)}
      when "set_physical_price" then {physical_from_price_cents: money_to_cents(@value)}
      when "set_lead_time" then {lead_time_days: integer_value(@value)}
      else {}
      end
    end

    def money_to_cents(value)
      raise ArgumentError, "A price value is required." if value.blank?
      decimal = BigDecimal(value.to_s)
      raise ArgumentError, "Price cannot be negative." if decimal.negative?
      (decimal * 100).round.to_i
    end

    def integer_value(value)
      raise ArgumentError, "A lead-time value is required." if value.blank?
      integer = Integer(value, 10)
      raise ArgumentError, "Lead time must be between 0 and 365 days." unless integer.between?(0, 365)
      integer
    rescue ArgumentError
      raise ArgumentError, "Lead time must be a whole number between 0 and 365 days."
    end
  end
end
