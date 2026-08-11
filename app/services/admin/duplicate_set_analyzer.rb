module Admin
  class DuplicateSetAnalyzer
    LIMIT = 100

    Result = Struct.new(:generated_at, :problem_count, :set_count, :sets, keyword_init: true)

    def self.call
      new.call
    end

    def call
      duplicate_files = Problem.where(category: "duplicate", problematic_type: "ModelFile")
        .includes(problematic: {model: :library})
        .filter_map(&:problematic)
        .select { |file| file.digest.present? }

      digests = duplicate_files.map(&:digest).uniq.first(LIMIT)
      sets = digests.filter_map { |digest| build_set(digest) }
      sets.sort_by! { |set| [set[:cleanup_candidate] ? 0 : 1, set[:models].size, set[:digest].to_s] }

      Result.new(
        generated_at: Time.current,
        problem_count: Problem.where(category: "duplicate").count,
        set_count: sets.size,
        sets: sets
      )
    end

    private

    def build_set(digest)
      files = ModelFile.where(digest: digest).includes(model: :library).order(:id).to_a
      return nil if files.size < 2

      members = files.map { |file| member(file) }
      existing = members.select { |m| m[:storage_exists] == true }
      models = members.map { |m| m[:model_id] }.compact.uniq
      libraries = members.map { |m| m[:library] }.compact.uniq
      same_model_only = models.one?
      cleanup_candidate = same_model_only && existing.size > 1
      recommended = cleanup_candidate ? choose_recommended(existing) : nil

      classification = if cleanup_candidate
        :same_model_redundant
      elsif models.size > 1 && libraries.size > 1
        :shared_cross_library
      elsif models.size > 1
        :shared_cross_model
      elsif existing.size < 2
        :insufficient_existing_copies
      else
        :review_only
      end

      {
        digest: digest,
        size: files.map(&:size).compact.max,
        members: members,
        member_count: members.size,
        existing_count: existing.size,
        missing_count: members.count { |m| m[:storage_exists] == false },
        libraries: libraries,
        models: models,
        same_model_only: same_model_only,
        cleanup_candidate: cleanup_candidate,
        classification: classification,
        explanation: explanation_for(classification, members),
        recommended_id: recommended&.dig(:id),
        recommendation_reason: recommendation_reason(recommended)
      }
    end

    def member(file)
      model = file.model
      storage_exists = begin
        file.exists_on_storage?
      rescue
        nil
      end

      three_d_count = model ? model.model_files.count(&:is_3d_model?) : 0

      {
        id: file.id,
        filename: file.filename,
        path: file.path_within_library,
        library: model&.library&.name,
        model_id: model&.id,
        model_name: model&.name,
        size: file.size,
        extension: file.extension,
        is_3d_model: file.is_3d_model?,
        only_3d_in_model: file.is_3d_model? && three_d_count == 1,
        preview_ref: Model.where(preview_file_id: file.id).exists?,
        entrypoint_ref: Model.where(entrypoint_id: file.id).exists?,
        storage_exists: storage_exists,
        problem_id: Problem.where(category: "duplicate", problematic: file).pick(:id)
      }
    end

    def choose_recommended(existing)
      existing.max_by do |member|
        [
          member[:preview_ref] ? 1 : 0,
          member[:entrypoint_ref] ? 1 : 0,
          member[:only_3d_in_model] ? 1 : 0,
          member[:is_3d_model] ? 1 : 0,
          -member[:id]
        ]
      end
    end

    def explanation_for(classification, members)
      case classification
      when :same_model_redundant
        "The same model contains more than one existing file with exactly identical content. This is a real cleanup candidate. Keep one copy and remove only the redundant copy or copies from this same model."
      when :shared_cross_model
        "These files have different names or paths, but their binary contents are exactly identical. They belong to different catalogue models, so this is treated as a shared/reused asset, not a cleanup candidate. No action is recommended."
      when :shared_cross_library
        "These files are byte-for-byte identical but belong to different catalogue models and different libraries. They are protected shared/reused assets. No action is recommended."
      when :insufficient_existing_copies
        "Fewer than two physical copies currently exist, so there is nothing safe to deduplicate. Review only."
      else
        "The files share the same exact digest, but this set is not eligible for automatic cleanup. Review only."
      end
    end

    def recommendation_reason(member)
      return nil unless member
      return "Currently used as a model preview" if member[:preview_ref]
      return "Currently used as an entrypoint" if member[:entrypoint_ref]
      return "Only 3D file in its model" if member[:only_3d_in_model]
      return "Existing 3D source with lowest record ID" if member[:is_3d_model]

      "Existing source with lowest record ID"
    end
  end
end
