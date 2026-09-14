module Admin
  class NestingMerger
    Result = Struct.new(
      :parent_id,
      :child_id,
      :child_name,
      :files_before,
      :parent_files_after,
      :child_destroyed,
      :preview_candidates_moved,
      :preview_candidates_deduplicated,
      :collection_preview_refs_moved,
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

      moved = 0
      deduplicated = 0
      collection_refs = 0

      ActiveRecord::Base.transaction do
        moved, deduplicated = transfer_preview_enrichment_candidates!(parent, child)
        collection_refs = transfer_collection_preview_references!(parent, child)

        # Use Manyfold's native merge implementation so file adoption, filename
        # conflict handling, metadata inheritance and child destruction follow the
        # application's own supported behavior.
        parent.merge!(child)
      end

      parent.reload

      raise "Child model still exists after merge." if Model.exists?(child_id)

      Result.new(
        parent_id: parent.id,
        child_id: child_id,
        child_name: child_name,
        files_before: files_before,
        parent_files_after: parent.model_files.count,
        child_destroyed: true,
        preview_candidates_moved: moved,
        preview_candidates_deduplicated: deduplicated,
        collection_preview_refs_moved: collection_refs
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

    def transfer_preview_enrichment_candidates!(parent, child)
      return [0, 0] unless defined?(PreviewEnrichmentCandidate)

      moved = 0
      deduplicated = 0

      PreviewEnrichmentCandidate.where(model_id: child.id).find_each do |candidate|
        duplicate = PreviewEnrichmentCandidate.where(model_id: parent.id, fingerprint: candidate.fingerprint).where.not(id: candidate.id).exists?

        if duplicate
          candidate.destroy!
          deduplicated += 1
        else
          candidate.update!(model_id: parent.id)
          moved += 1
        end
      end

      [moved, deduplicated]
    end

    def transfer_collection_preview_references!(parent, child)
      return 0 unless defined?(Collection)

      Collection.where(preview_model_id: child.id).update_all(
        preview_model_id: parent.id,
        updated_at: Time.current
      )
    end

    def storage_exists?(file)
      file.exists_on_storage? == true
    rescue
      false
    end
  end
end
