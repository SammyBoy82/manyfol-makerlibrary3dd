module Admin
  class IntegrityStaleCleaner
    SUPPORTED_CATEGORIES = %w[missing duplicate nesting].freeze

    Result = Struct.new(:category, :checked, :cleared, :skipped, :errors, keyword_init: true)

    def self.call(category)
      new(category).call
    end

    def initialize(category)
      @category = category.to_s
      raise ArgumentError, "Unsupported integrity cleanup category: #{@category}" unless SUPPORTED_CATEGORIES.include?(@category)
    end

    def call
      checked = 0
      cleared = 0
      skipped = 0
      errors = []

      Problem.where(category: @category).find_each do |problem|
        checked += 1

        begin
          if stale?(problem)
            problem.destroy!
            cleared += 1
          else
            skipped += 1
          end
        rescue => error
          skipped += 1
          errors << {problem_id: problem.id, error: "#{error.class}: #{error.message}"}
        end
      end

      Result.new(
        category: @category,
        checked: checked,
        cleared: cleared,
        skipped: skipped,
        errors: errors.first(50)
      )
    end

    private

    def stale?(problem)
      case @category
      when "missing"
        stale_missing?(problem)
      when "duplicate"
        stale_duplicate?(problem)
      when "nesting"
        stale_nesting?(problem)
      else
        false
      end
    end

    def stale_missing?(problem)
      object = problem.problematic
      return true unless object
      return object.exists_on_storage? if object.respond_to?(:exists_on_storage?)

      false
    rescue
      false
    end

    def stale_duplicate?(problem)
      file = problem.problematic
      return true unless file
      return false unless file.is_a?(ModelFile)

      file.duplicates.none?
    rescue
      false
    end

    def stale_nesting?(problem)
      model = problem.problematic
      return true unless model
      return false unless model.is_a?(Model)

      nested_exists = model.library.models.where.not(id: model.id).any? { |candidate| model.contains?(candidate) }
      parent_exists = model.parents.any?

      !nested_exists && !parent_exists
    rescue
      false
    end
  end
end
