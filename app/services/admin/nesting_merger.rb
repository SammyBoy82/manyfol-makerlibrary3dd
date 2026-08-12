module Admin
  class NestingMerger
    Result = Struct.new(
      :parent_id,
      :child_id,
      :child_name,
      :files_before,
      :parent_files_after,
      :child_destroyed,
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
      preview = Admin::NestingMergePreview.call(parent_id: @parent_id, child_id: @child_id)
      raise ArgumentError, preview.blockers.join(" ") if preview.blockers.any?

      parent = Model.find(preview.parent[:id])
      child = Model.find(preview.child[:id])

      revalidate!(parent, child)

      child_name = child.name
      files_before = child.model_files.count
      child_id = child.id

      # Use Manyfold's native merge implementation so file adoption, filename
      # conflict handling, metadata inheritance and child destruction follow the
      # application's own supported behavior.
      parent.merge!(child)

      parent.reload

      raise "Child model still exists after merge." if Model.exists?(child_id)

      Result.new(
        parent_id: parent.id,
        child_id: child_id,
        child_name: child_name,
        files_before: files_before,
        parent_files_after: parent.model_files.count,
        child_destroyed: true
      )
    end

    private

    def revalidate!(parent, child)
      raise ArgumentError, "Parent and child must be different models." if parent.id == child.id
      raise ArgumentError, "Parent and child are no longer in the same library." unless parent.library_id == child.library_id
      raise ArgumentError, "Child is no longer nested inside the selected parent path." unless parent.contains?(child)

      missing = child.model_files.reject { |file| storage_exists?(file) }
      raise ArgumentError, "Merge blocked: #{missing.size} child file(s) are not present on storage." if missing.any?

      descendants = child.library.models.where.not(id: [parent.id, child.id]).select { |candidate| child.contains?(candidate) }
      raise ArgumentError, "Merge blocked: child still contains #{descendants.size} nested catalogue model(s). Merge deepest children first." if descendants.any?

      preview = Admin::NestingMergePreview.call(parent_id: parent.id, child_id: child.id)
      raise ArgumentError, preview.blockers.join(" ") if preview.blockers.any?
    end

    def storage_exists?(file)
      file.exists_on_storage? == true
    rescue
      false
    end
  end
end
