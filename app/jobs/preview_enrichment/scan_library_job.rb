module PreviewEnrichment
  class ScanLibraryJob < ApplicationJob
    queue_as :default

    DEFAULT_MODEL_CONCURRENCY = 2

    def perform(library_id)
      library = Library.find_by(id: library_id)

      return unless library

      cache_key =
        self.class.cache_key(library.id)

      started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      Rails.logger.info(
        {
          event:
            "preview_enrichment_library_scan_started",
          library_id: library.id,
          library_name: library.name,
          model_concurrency: model_concurrency,
          provider_concurrency:
            ENV.fetch(
              "PREVIEW_ENRICHMENT_PROVIDER_CONCURRENCY",
              "4"
            ).to_i
        }.to_json
      )

      model_ids =
        library.models.pluck(:id)

      queue = Queue.new

      model_ids.each do |model_id|
        queue << model_id
      end

      totals = {
        scanned: 0,
        eligible: 0,
        discovered: 0,
        persisted: 0,
        failed: 0
      }

      mutex = Mutex.new

      worker_count = [
        model_concurrency,
        model_ids.length
      ].min

      workers =
        worker_count.times.map do
          Thread.new do
            Rails.application.executor.wrap do

              loop do
                model_id =
                  begin
                    queue.pop(true)
                  rescue ThreadError
                    break
                  end

                begin
                  ActiveRecord::Base
                    .connection_pool
                    .with_connection do

                    current_model =
                      Model.find_by(id: model_id)

                    next unless current_model

                    mutex.synchronize do
                      totals[:scanned] += 1
                    end

                    eligibility =
                      PreviewEnrichment::Eligibility
                        .new(current_model)

                    next unless eligibility.eligible?

                    mutex.synchronize do
                      totals[:eligible] += 1
                    end

                    result =
                      PreviewEnrichment::Runner
                        .new(current_model)
                        .call

                    mutex.synchronize do
                      totals[:discovered] +=
                        result[:discovered].to_i

                      totals[:persisted] +=
                        result[:persisted].to_i
                    end
                  end

                rescue StandardError => error
                  mutex.synchronize do
                    totals[:failed] += 1
                  end

                  Rails.logger.error(
                    {
                      event:
                        "preview_enrichment_model_scan_failed",
                      library_id: library.id,
                      model_id: model_id,
                      error_class: error.class.name,
                      error: error.message
                    }.to_json
                  )
                end
              end

            end
          end
        end

      workers.each(&:join)

      elapsed =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        ) - started_at

      Rails.logger.info(
        {
          event:
            "preview_enrichment_library_scan_completed",
          library_id: library.id,
          library_name: library.name,
          models_scanned: totals[:scanned],
          eligible_models: totals[:eligible],
          candidates_discovered:
            totals[:discovered],
          candidates_persisted:
            totals[:persisted],
          failed_models: totals[:failed],
          scan_seconds: elapsed.round(3),
          model_concurrency: model_concurrency
        }.to_json
      )

    ensure
      if defined?(cache_key) && cache_key
        Rails.cache.delete(cache_key)
      end
    end

    def self.cache_key(library_id)
      "preview_enrichment:library_scan:#{library_id}"
    end

    private

    def model_concurrency
      value =
        ENV.fetch(
          "PREVIEW_ENRICHMENT_MODEL_CONCURRENCY",
          DEFAULT_MODEL_CONCURRENCY
        ).to_i

      value.clamp(1, 8)
    end
  end
end
