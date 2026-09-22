module ModelListable
  extend ActiveSupport::Concern

  included do
    include TagListable
    include Filterable
    include Sortable
  end

  private

  def prepare_model_list
    # Ordering
    @models = apply_sort_order(@models)

    @tags, @unrelated_tag_count = generate_tag_list(@models, @filter.tags)
    @tags, @kv_tags = split_key_value_tags(@tags)
    @unrelated_tag_count = nil unless @filter.any?

    page = params[:page] || 1

    allowed_per_page = [24, 48, 100]

    requested_per_page =
      params[:per_page].to_i

    saved_per_page =
      helpers.pagination_settings["per_page"].to_i

    @per_page =
      if allowed_per_page.include?(requested_per_page)
        requested_per_page
      elsif allowed_per_page.include?(saved_per_page)
        saved_per_page
      else
        48
      end

    @models =
      @models
        .page(page)
        .per(@per_page)

    # Load extra data
    @models = @models.includes [:creator, :collections]
    @models = @models.preload [:model_files, :preview_file] # Use preload query to avoid joining JSON fields
  end
end
