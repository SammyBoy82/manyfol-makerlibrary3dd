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
      recommended = choose_recommended(existing)

      {
        digest: digest,
        size: files.map(&:size).compact.max,
        members: members,
        member_count: members.size,
        existing_count: existing.size,
        missing_count: members.count { |m| m[:storage_exists] == false },
        libraries: members.map { |m| m[:library] }.compact.uniq,
        models: members.map { |m| m[:model_id] }.compact.uniq,
        same_model_only: members.map { |m| m[:model_id] }.compact.uniq.one?,
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

    def recommendation_reason(member)
      return "No existing copy available" unless member
      return "Currently used as a model preview" if member[:preview_ref]
      return "Currently used as an entrypoint" if member[:entrypoint_ref]
      return "Only 3D file in its model" if member[:only_3d_in_model]
      return "Existing 3D source with lowest record ID" if member[:is_3d_model]

      "Existing source with lowest record ID"
    end
  end
end
