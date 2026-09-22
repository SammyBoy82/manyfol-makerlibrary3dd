class Admin::TaxonomyAnalyzer
  def summary
    {
      models: Model.count,
      libraries: Library.count,
      collections: Collection.count,
      tags: ActsAsTaggableOn::Tag.count,
      untagged_models: untagged_models.count,
      uncollected_models: uncollected_models.count,
      empty_collections: empty_collections.count,
      duplicate_tag_groups: duplicate_tag_groups.count
    }
  end

  def untagged_models
    Model.where.not(
      id:
        ActsAsTaggableOn::Tagging
          .where(
            taggable_type: "Model",
            context: "tags"
          )
          .select(:taggable_id)
    )
  end

  def uncollected_models
    Model.where.missing(:collections_models)
  end

  def empty_collections
    Collection.where.missing(:collections_models)
  end

  def duplicate_tag_groups
    groups =
      ActsAsTaggableOn::Tag
        .order(:name)
        .pluck(:id, :name, :taggings_count)
        .group_by do |_id, name, _count|
          normalize_tag(name)
        end

    groups
      .select do |normalized, tags|
        normalized.present? &&
          tags.size > 1
      end
      .sort_by do |normalized, _tags|
        normalized
      end
  end

  private

  def normalize_tag(name)
    name
      .to_s
      .downcase
      .strip
      .gsub(/[_-]+/, " ")
      .gsub(/[^\p{Alnum}\s]/u, "")
      .gsub(/\s+/, " ")
  end
end
