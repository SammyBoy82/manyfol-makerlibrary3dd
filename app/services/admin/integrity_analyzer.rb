module Admin
  class IntegrityAnalyzer
    SAMPLE_LIMIT = 20

    CATEGORY_META = {
      "missing" => {risk: :danger, mode: :review, action: "Verify missing storage state"},
      "empty" => {risk: :warning, mode: :review, action: "Verify empty-file state"},
      "duplicate" => {risk: :warning, mode: :review, action: "Compare duplicate candidates"},
      "nesting" => {risk: :warning, mode: :structural, action: "Preview nesting repair"},
      "file_naming" => {risk: :info, mode: :structural, action: "Preview organizer changes"},
      "inefficient" => {risk: :info, mode: :conversion, action: "Review conversion opportunity"},
      "non_manifold" => {risk: :secondary, mode: :manual, action: "Manual geometry review"},
      "inside_out" => {risk: :secondary, mode: :manual, action: "Manual geometry review"}
    }.freeze

    DEFAULT_META = {risk: :secondary, mode: :manual, action: "Manual review"}.freeze

    Result = Struct.new(:generated_at, :total, :groups, keyword_init: true)

    def self.call
      new.call
    end

    def call
      counts = Problem.group(:category).count
      groups = counts.sort_by { |category, _| category.to_s }.map do |category, count|
        build_group(category.to_s, count)
      end

      Result.new(generated_at: Time.current, total: counts.values.sum, groups: groups)
    end

    private

    def build_group(category, count)
      meta = CATEGORY_META.fetch(category, DEFAULT_META)
      problems = Problem.where(category: category).order(created_at: :desc).limit(SAMPLE_LIMIT)

      {
        category: category,
        count: count,
        risk: meta[:risk],
        mode: meta[:mode],
        proposed_action: meta[:action],
        samples: problems.map { |problem| sample(problem) }
      }
    end

    def sample(problem)
      object = problem.problematic
      {
        id: problem.id,
        problematic_type: problem.problematic_type,
        problematic_id: problem.problematic_id,
        label: object_label(object),
        library: object_library(object),
        path: object_path(object),
        size: object_size(object),
        storage_exists: storage_exists(object),
        created_at: problem.created_at
      }
    rescue => error
      {
        id: problem.id,
        problematic_type: problem.problematic_type,
        problematic_id: problem.problematic_id,
        label: "Unable to inspect",
        library: nil,
        path: nil,
        size: nil,
        storage_exists: nil,
        created_at: problem.created_at,
        error: "#{error.class}: #{error.message}"
      }
    end

    def object_label(object)
      return "Deleted object" unless object
      return object.name_and_filename if object.respond_to?(:name_and_filename)
      return object.name if object.respond_to?(:name)
      return object.url if object.respond_to?(:url)
      "#{object.class.name} ##{object.id}"
    end

    def object_library(object)
      return nil unless object
      return object.library.name if object.respond_to?(:library) && object.library
      return object.model.library.name if object.respond_to?(:model) && object.model&.library
      nil
    end

    def object_path(object)
      return nil unless object
      return object.path_within_library if object.respond_to?(:path_within_library)
      return object.path if object.respond_to?(:path)
      nil
    end

    def object_size(object)
      return nil unless object
      return object.size if object.respond_to?(:size)
      nil
    end

    def storage_exists(object)
      return nil unless object
      return object.exists_on_storage? if object.respond_to?(:exists_on_storage?)
      nil
    rescue
      nil
    end
  end
end
