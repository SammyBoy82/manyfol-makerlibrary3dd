module Admin
  class CommercialSkuGenerator
    Result = Struct.new(:requested, :created, :existing, :errors, keyword_init: true)

    def self.call(model_ids: nil)
      new(model_ids: model_ids).call
    end

    def initialize(model_ids: nil)
      @model_ids = Array(model_ids).map(&:to_i).uniq.reject(&:zero?)
    end

    def call
      scope = Model.order(:id)
      scope = scope.where(id: @model_ids) if @model_ids.any?

      created = 0
      existing = 0
      errors = []

      scope.find_each do |model|
        begin
          metadata = ModelCommercialMetadata.find_or_initialize_by(model_id: model.id)

          if metadata.sku.present?
            existing += 1
            next
          end

          metadata.sku = sku_for(model)
          metadata.save!
          created += 1
        rescue => error
          errors << {model_id: model.id, error: "#{error.class}: #{error.message}"}
        end
      end

      Result.new(
        requested: scope.count,
        created: created,
        existing: existing,
        errors: errors.first(100)
      )
    end

    private

    def sku_for(model)
      "ML3D-L#{model.library_id.to_i.to_s.rjust(3, '0')}-M#{model.id.to_i.to_s.rjust(6, '0')}"
    end
  end
end
