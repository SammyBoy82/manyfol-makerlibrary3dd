module Admin
  class MissingRecordRemover
    MAX_SELECTION = 250

    Result = Struct.new(:requested, :removed, :skipped, :preview_refs_cleared, :entrypoint_refs_cleared, :errors, keyword_init: true)

    def self.call(problem_ids)
      new(problem_ids).call
    end

    def initialize(problem_ids)
      @problem_ids = Array(problem_ids).map(&:to_i).uniq.first(MAX_SELECTION)
    end

    def call
      removed = 0
      skipped = 0
      preview_refs_cleared = 0
      entrypoint_refs_cleared = 0
      errors = []

      Problem.where(id: @problem_ids, category: "missing").find_each do |problem|
        begin
          file = problem.problematic

          unless file.is_a?(ModelFile)
            skipped += 1
            next
          end

          # Re-check storage immediately before any database mutation.
          if file.exists_on_storage?
            skipped += 1
            next
          end

          ModelFile.transaction do
            preview_count = Model.where(preview_file_id: file.id).update_all(preview_file_id: nil, updated_at: Time.current)
            entrypoint_count = Model.where(entrypoint_id: file.id).update_all(entrypoint_id: nil, updated_at: Time.current)

            preview_refs_cleared += preview_count
            entrypoint_refs_cleared += entrypoint_count

            # The source is already absent, so this removes only the database object
            # and its normal dependent records/callback state. No storage delete is called.
            file.destroy!
          end

          removed += 1
        rescue => error
          skipped += 1
          errors << {problem_id: problem.id, error: "#{error.class}: #{error.message}"}
        end
      end

      Result.new(
        requested: @problem_ids.size,
        removed: removed,
        skipped: skipped,
        preview_refs_cleared: preview_refs_cleared,
        entrypoint_refs_cleared: entrypoint_refs_cleared,
        errors: errors.first(50)
      )
    end
  end
end
