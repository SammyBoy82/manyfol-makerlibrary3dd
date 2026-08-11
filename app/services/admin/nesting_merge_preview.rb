module Admin
  class NestingMergePreview
    Result = Struct.new(
      :generated_at,
      :parent,
      :child,
      :relative_path,
      :files,
      :metadata,
      :warnings,
      keyword_init: true
    )

    def self.call(parent_id:, child_id:)
      new(parent_id: parent_id, child_id: child_id).call
    end

    def initialize(parent_id:, child_id:)
      @parent_id = parent_id.to_i
      @child_id = child_id.to_i
    end

    def call
      parent = Model.includes(:library, :creator, :collections, :tags, :links, :model_files).find_by(id: @parent_id)
      child = Model.includes(:library, :creator, :collections, :tags, :links, :model_files).find_by(id: @child_id)

      raise ArgumentError, "Parent model was not found." unless parent
      raise ArgumentError, "Child model was not found." unless child
      raise ArgumentError, "Parent and child must be different models." if parent.id == child.id
      raise ArgumentError, "Parent and child must be in the same library." unless parent.library_id == child.library_id
      raise ArgumentError, "Selected child is not physically inside the selected parent path." unless parent.contains?(child)

      relative_path = Pathname.new(child.path).relative_path_from(Pathname.new(parent.path)).to_s

      Result.new(
        generated_at: Time.current,
        parent: model_summary(parent),
        child: model_summary(child),
        relative_path: relative_path,
        files: file_impacts(parent, child, relative_path),
        metadata: metadata_impacts(parent, child),
        warnings: warnings(parent, child)
      )
    end

    private

    def model_summary(model)
      {
        id: model.id,
        name: model.name,
        path: model.path,
        library: model.library&.name,
        files: model.model_files.count,
        three_d: model.model_files.count(&:is_3d_model?),
        images: model.model_files.count(&:is_image?),
        preview_file_id: model.preview_file_id,
        entrypoint_id: model.entrypoint_id,
        creator: model.creator&.name,
        license: model.license,
        caption: model.caption,
        notes_present: model.notes.present?,
        collections: model.collections.map(&:name),
        tags: model.tag_list,
        links: model.links.map(&:url)
      }
    end

    def file_impacts(parent, child, relative_path)
      child.model_files.order(:id).map do |file|
        destination = File.join(relative_path, file.filename)
        existing = parent.model_files.find_by(filename: destination)
        exact_duplicate = existing.present? && file.digest.present? && file.digest == existing.digest

        final_destination = if existing && !exact_duplicate
          "#{File.basename(destination, ".*")}_#{file.digest.to_s.first(6)}#{File.extname(destination)}"
        else
          destination
        end

        {
          id: file.id,
          filename: file.filename,
          source_path: file.path_within_library,
          destination_filename: final_destination,
          extension: file.extension,
          size: file.size,
          is_3d_model: file.is_3d_model?,
          is_image: file.is_image?,
          storage_exists: storage_exists?(file),
          action: exact_duplicate ? :deduplicate_database_record : :adopt_into_parent,
          conflict: existing.present?,
          exact_duplicate: exact_duplicate,
          existing_parent_file_id: existing&.id
        }
      end
    end

    def metadata_impacts(parent, child)
      {
        creator: scalar_impact(parent.creator&.name, child.creator&.name),
        license: scalar_impact(parent.license, child.license),
        caption: scalar_impact(parent.caption, child.caption),
        notes: scalar_impact(parent.notes.presence, child.notes.presence, values: false),
        sensitive: scalar_impact(parent.sensitive, child.sensitive),
        collections_added: child.collections.map(&:name) - parent.collections.map(&:name),
        tags_added: child.tag_list - parent.tag_list,
        links_added: child.links.map(&:url) - parent.links.map(&:url)
      }
    end

    def scalar_impact(parent_value, child_value, values: true)
      result = if parent_value.present?
        :keep_parent
      elsif child_value.present?
        :inherit_child
      else
        :unchanged_blank
      end

      data = {action: result}
      if values
        data[:parent] = parent_value
        data[:child] = child_value
      end
      data
    end

    def warnings(parent, child)
      result = []
      result << "Child model database record will be destroyed after its files and metadata are merged." 
      result << "Parent name and path remain unchanged."
      result << "Child preview/entrypoint selection is not automatically promoted if the parent already has its own selection."
      result << "A fresh backup is strongly recommended immediately before enabling Apply."
      result << "Child has no model files." if child.model_files.empty?
      result << "Parent already contains other nested catalogue models." if parent.library.models.where.not(id: [parent.id, child.id]).any? { |candidate| parent.contains?(candidate) }
      result
    end

    def storage_exists?(file)
      file.exists_on_storage? == true
    rescue
      nil
    end
  end
end
