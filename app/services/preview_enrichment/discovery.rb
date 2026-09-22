module PreviewEnrichment
  class Discovery
    PROVIDERS = [
      Providers::ExistingLink,
      Providers::SourcePageImage,
      Providers::CultsSearch,
      Providers::ThangsSearch,
      Providers::PrintablesSearch,
      Providers::MyMinifactorySearch,
    ].freeze

    DEFAULT_PROVIDER_CONCURRENCY = 4

    def initialize(model)
      @model = model
    end

    def call
      eligibility = Eligibility.new(model)

      return [] unless eligibility.eligible?

      search_context =
        PreviewEnrichment::SearchContext.new(model)

      unless search_context.searchable?
        Rails.logger.info(
          {
            event: "preview_enrichment_skipped_generic_model",
            model_id: model.id,
            model_name: model.name,
            path: model.path,
            context: search_context.evidence
          }.to_json
        )

        return []
      end

      started_at = Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      )

      raw_candidates =
        parallel_provider_searches

      filtered =
        RelevanceFilter
          .new(model, raw_candidates)
          .call

      elapsed =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) - started_at

      Rails.logger.info(
        {
          event: "preview_enrichment_relevance_filter",
          model_id: model.id,
          model_name: model.name,
          raw_candidates: raw_candidates.length,
          accepted_candidates: filtered.length,
          removed_candidates:
            raw_candidates.length - filtered.length,
          discovery_seconds: elapsed.round(3),
          provider_concurrency: provider_concurrency
        }.to_json
      )

      filtered
    end

    private

    attr_reader :model

    def parallel_provider_searches
      queue = Queue.new

      PROVIDERS.each do |provider_class|
        queue << provider_class
      end

      results = []
      mutex = Mutex.new

      worker_count = [
        provider_concurrency,
        PROVIDERS.length
      ].min

      workers =
        worker_count.times.map do
          Thread.new do
            Rails.application.executor.wrap do

              loop do
                provider_class =
                  begin
                    queue.pop(true)
                  rescue ThreadError
                    break
                  end

                provider_started =
                  Process.clock_gettime(
                    Process::CLOCK_MONOTONIC
                  )

                provider_results = []

                begin
                  ActiveRecord::Base
                    .connection_pool
                    .with_connection do

                    # Independent ActiveRecord object per thread.
                    threaded_model =
                      Model.find(model.id)

                    provider_results =
                      provider_class
                        .new(threaded_model)
                        .search
                  end

                rescue StandardError => error
                  Rails.logger.error(
                    {
                      event:
                        "preview_enrichment_provider_failed",
                      model_id: model.id,
                      provider: provider_class.name,
                      error: error.class.name,
                      message: error.message
                    }.to_json
                  )

                  provider_results = []
                end

                provider_elapsed =
                  Process.clock_gettime(
                    Process::CLOCK_MONOTONIC
                  ) - provider_started

                Rails.logger.info(
                  {
                    event:
                      "preview_enrichment_provider_timing",
                    model_id: model.id,
                    provider: provider_class.name,
                    results:
                      Array(provider_results).length,
                    seconds:
                      provider_elapsed.round(3)
                  }.to_json
                )

                mutex.synchronize do
                  results.concat(
                    Array(provider_results)
                  )
                end
              end
            end
          end
        end

      workers.each(&:join)

      results
    end

    def provider_concurrency
      value =
        ENV.fetch(
          "PREVIEW_ENRICHMENT_PROVIDER_CONCURRENCY",
          DEFAULT_PROVIDER_CONCURRENCY
        ).to_i

      value.clamp(1, PROVIDERS.length)
    end
  end
end
