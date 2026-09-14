module PreviewEnrichment
  class Runner
    def initialize(model)
      @model = model
    end

    def call
      eligibility = Eligibility.new(model)

      unless eligibility.eligible?
        return {
          eligible: false,
          reason: eligibility.reason,
          discovered: 0,
          persisted: 0
        }
      end

      candidates = Discovery.new(model).call
      persisted = CandidatePersister.new(model).persist(candidates)

      {
        eligible: true,
        reason: :missing_real_images,
        discovered: candidates.count,
        persisted: persisted.count,
        candidates: persisted
      }
    end

    private

    attr_reader :model
  end
end
