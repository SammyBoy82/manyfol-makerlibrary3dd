module Admin
  class DuplicateRecordRemover
    Result = Struct.new(
      :canonical_id,
      :requested,
      :removed,
      :skipped,
      :preview_refs_moved,
      :entrypoint_refs_moved,
      :errors,
      keyword_init: true
    )

    def self.call(canonical_id:, remove_ids:)
      new(canonical_id: canonical_id, remove_ids: remove_ids).call
    end

    def initialize(canonical_id:, remove_ids:)
      @canonical_id = canonical_id.to_i
      @remove_ids = Array(remove_ids).map(&:to_i).uniq.reject { |id| id == @canonical_id }.first(50)
    end

    def call
      canonical = ModelFile.includes(model: :library).find_by(id: @canonical_id)
      raise ArgumentError, "Canonical ModelFile was not found." unless canonical
      raise ArgumentError, "Canonical file has no digest." if canonical.digest.blank?
      raise ArgumentError, "Canonical source is not present on storage." unless storage_exists?(canonical)

      removed = 0
      skipped = 0
      preview_refs_moved = 0
      entrypoint_refs_moved = 0
      errors = []

      @remove_ids.each do |remove_id|
        begin
          candidate = ModelFile.includes(model: :library).find_by(id: remove_id)

          unless eligible?(canonical, candidate)
            skipped += 1
            next
          end

          ModelFile.transaction do
            # Revalidate all safety conditions again inside the transaction.
            canonical.reload
            candidate.reload
            raise ActiveRecord::Rollback unless eligible?(canonical, candidate)

            preview_count = Model.where(preview_file_id: candidate.id).update_all(
              preview_file_id: canonical.id,
              updated_at: Time.current
            )
            entrypoint_count = Model.where(entrypoint_id: candidate.id).update_all(
              entrypoint_id: canonical.id,
              updated_at: Time.current
            )

            # This Phase 4 action is intentionally limited to same-model duplicates.
            # The redundant physical source is removed only after digest, model and
            # storage checks prove that an identical canonical copy remains.
            candidate.delete_from_disk_and_destroy

            preview_refs_moved += preview_count
            entrypoint_refs_moved += entrypoint_count
            removed += 1
          end
        rescue => error
          skipped += 1
          errors << {file_id: remove_id, error: "#{error.class}: #{error.message}"}
        end
      end

      Result.new(
        canonical_id: canonical.id,
        requested: @remove_ids.size,
        removed: removed,
        skipped: skipped,
        preview_refs_moved: preview_refs_moved,
        entrypoint_refs_moved: entrypoint_refs_moved,
        errors: errors.first(50)
      )
    end

    private

    def eligible?(canonical, candidate)
      return false unless candidate.is_a?(ModelFile)
      return false if candidate.id == canonical.id
      return false if canonical.digest.blank? || candidate.digest.blank?
      return false unless canonical.digest == candidate.digest
      return false unless canonical.model_id == candidate.model_id
      return false unless storage_exists?(canonical)
      return false unless storage_exists?(candidate)

      true
    rescue
      false
    end

    def storage_exists?(file)
      file.exists_on_storage? == true
    rescue
      false
    end
  end
end
