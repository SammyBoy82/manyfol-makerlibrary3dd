module Admin
  class CommercialMetadataController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization

      @query = params[:q].to_s.strip
      @library_id = params[:library_id].presence
      @channel = params[:channel].presence

      scope = Model.includes(:library).order(:name)
      scope = scope.where(library_id: @library_id) if @library_id
      scope = scope.where("models.name ILIKE ?", "%#{Model.sanitize_sql_like(@query)}%") if @query.present?

      if @channel.present?
        metadata_scope = ModelCommercialMetadata.all
        metadata_scope = case @channel
        when "member"
          metadata_scope.where(member_download_enabled: true)
        when "digital"
          metadata_scope.where(digital_sale_enabled: true)
        when "physical"
          metadata_scope.where(physical_sale_enabled: true)
        when "quote"
          metadata_scope.where(custom_quote_enabled: true)
        when "featured"
          metadata_scope.where(featured: true)
        else
          metadata_scope
        end
        scope = scope.where(id: metadata_scope.select(:model_id))
      end

      @models = scope.limit(250)
      @metadata_by_model = ModelCommercialMetadata.where(model_id: @models.map(&:id)).index_by(&:model_id)
      @libraries = Library.order(:name)

      @stats = {
        models: Model.count,
        configured: ModelCommercialMetadata.count,
        digital: ModelCommercialMetadata.digital_sale.count,
        physical: ModelCommercialMetadata.physical_sale.count,
        quote: ModelCommercialMetadata.custom_quote.count,
        featured: ModelCommercialMetadata.featured.count
      }
    end

    def edit
      skip_policy_scope
      skip_authorization

      @model = Model.includes(:library).find(params[:model_id])
      @metadata = ModelCommercialMetadata.find_or_initialize_by(model_id: @model.id)
    end

    def update
      skip_authorization

      @model = Model.includes(:library).find(params[:model_id])
      @metadata = ModelCommercialMetadata.find_or_initialize_by(model_id: @model.id)

      attrs = metadata_params.to_h
      attrs["digital_price_cents"] = money_to_cents(attrs.delete("digital_price"))
      attrs["physical_from_price_cents"] = money_to_cents(attrs.delete("physical_from_price"))
      attrs["sku"] = attrs["sku"].presence
      attrs["lead_time_days"] = attrs["lead_time_days"].presence

      if @metadata.update(attrs)
        redirect_to edit_admin_commercial_metadata_path(model_id: @model.id), notice: "Commercial metadata saved for #{@model.name}."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def metadata_params
      params.require(:model_commercial_metadata).permit(
        :sku,
        :member_download_enabled,
        :digital_sale_enabled,
        :physical_sale_enabled,
        :custom_quote_enabled,
        :digital_price,
        :physical_from_price,
        :featured,
        :lead_time_days,
        :commercial_notes
      )
    end

    def money_to_cents(value)
      return nil if value.blank?

      decimal = BigDecimal(value.to_s)
      raise ArgumentError, "Price cannot be negative." if decimal.negative?

      (decimal * 100).round.to_i
    rescue ArgumentError
      nil
    end

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
