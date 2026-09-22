require "net/http"
require "json"
require "uri"

module PreviewEnrichment
  module Providers
    class BraveImageSearch < Base
      ENDPOINT = "https://api.search.brave.com/res/v1/images/search"

      MAX_RESULTS = 10

      TRUSTED_SOURCE_DOMAINS = %w[
        cults3d.com
        thingiverse.com
        myminifactory.com
        printables.com
        makerworld.com
        thangs.com
      ].freeze

      def search
        api_key = ENV["BRAVE_SEARCH_API_KEY"]

        if api_key.blank?
          Rails.logger.warn(
            event: "preview_enrichment_brave_missing_api_key",
            model_id: model.id
          )

          return []
        end

        queries.flat_map do |query|
          search_query(query, api_key)
        end
      end

      private

      def queries
        PreviewEnrichment::QueryBuilder
          .new(model)
          .queries
          .first(3)
      end

      def search_query(query, api_key)
        uri = URI(ENDPOINT)

        uri.query = URI.encode_www_form(
          q: query,
          count: MAX_RESULTS,
          country: "ALL",
          search_lang: "en",
          safesearch: "strict"
        )

        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        request["X-Subscription-Token"] = api_key

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: 5,
          read_timeout: 15
        ) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.warn(
            event: "preview_enrichment_brave_failed",
            model_id: model.id,
            query: query,
            http_status: response.code
          )

          return []
        end

        payload = JSON.parse(response.body)

        Array(payload["results"]).filter_map do |result|
          build_candidate(result, query)
        end
      rescue JSON::ParserError => error
        Rails.logger.warn(
          event: "preview_enrichment_brave_invalid_json",
          model_id: model.id,
          message: error.message
        )

        []
      end

      def build_candidate(result, query)
        source_url =
          result["source"] ||
          result.dig("source", "url") ||
          result["page_url"]

        image_url =
          result.dig("properties", "url") ||
          result["url"] ||
          result.dig("thumbnail", "src")

        return if image_url.blank?

        Candidate.new(
          provider: "brave_image_search",
          source_page_url: source_url,
          image_url: image_url,
          title: result["title"],
          creator: nil,
          license: nil,
          confidence: initial_confidence(source_url),
          match_method: "metadata_image_search",
          metadata: {
            query: query,
            source: result["source"],
            width: result.dig("properties", "width"),
            height: result.dig("properties", "height")
          }
        )
      end

      def initial_confidence(source_url)
        host =
          begin
            URI.parse(source_url.to_s).host&.downcase
          rescue URI::InvalidURIError
            nil
          end

        return 80 if trusted_source?(host)

        55
      end

      def trusted_source?(host)
        return false if host.blank?

        TRUSTED_SOURCE_DOMAINS.any? do |domain|
          host == domain || host.end_with?(".#{domain}")
        end
      end
    end
  end
end
