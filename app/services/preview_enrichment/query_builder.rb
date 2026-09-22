module PreviewEnrichment
  class QueryBuilder
    MAX_FILENAMES = 5

    def initialize(model)
      @model = model
    end

    def queries
      [
        primary_query,
        stl_query,
        creator_query,
        filename_query
      ].compact_blank.uniq
    end

    def evidence
      {
        model_id: model.id,
        name: model.name,
        path: model.path,
        creator: model.creator&.name,
        tags: model.tag_list,
        filenames: relevant_filenames,
        file_count: model.model_files.count,
        three_d_file_count: model.three_d_files.count,
        size_on_disk: model.size_on_disk,
        existing_links: existing_links
      }
    end

    private

    attr_reader :model

    def primary_query
      %("#{clean(model.name)}" 3D printable model)
    end

    def stl_query
      %("#{clean(model.name)}" STL)
    end

    def creator_query
      return if model.creator&.name.blank?

      %("#{clean(model.name)}" "#{clean(model.creator.name)}")
    end

    def filename_query
      filename = relevant_filenames.first
      return if filename.blank?

      %("#{clean(filename)}" STL)
    end

    def relevant_filenames
      model.three_d_files
        .map(&:basename)
        .uniq
        .first(MAX_FILENAMES)
    end

    def existing_links
      model.links.map(&:url)
    rescue NoMethodError
      []
    end

    def clean(value)
      value.to_s
        .tr("_-", " ")
        .squish
    end
  end
end
