require "net/http"
require "uri"
require "json"

module PreviewEnrichment
  module Providers
    class CultsSearch < Base
      ENDPOINT = URI("https://cults3d.com/graphql")
      MAX_RESULTS = 10
      MAX_QUERIES = 3

      def search
        return [] unless configured?

        candidates = []

        search_queries.each do |query|
          candidates.concat(search_cults(query: query))

          creator_hints.each do |creator|
            candidates.concat(
              search_cults(
                query: query,
                creator_nick: creator
              )
            )
          end
        end

        candidates
          .compact
          .uniq { |candidate| candidate.source_page_url }
          .sort_by { |candidate| -candidate.confidence.to_i }
          .first(MAX_RESULTS)
      rescue StandardError => error
        Rails.logger.warn(
          {
            event: "preview_enrichment_cults_search_failed",
            provider: "cults3d",
            model_id: model.id,
            error: error.class.name,
            message: error.message
          }.to_json
        )

        []
      end

      private

      def configured?
        ENV["CULTS_API_USER"].present? &&
          ENV["CULTS_API_PASSWORD"].present?
      end

      def search_queries
        PreviewEnrichment::QueryBuilder
          .new(model)
          .queries
          .first(MAX_QUERIES)
          .map { |query| clean_query(query) }
          .reject(&:blank?)
          .uniq
      end

      def clean_query(query)
        query.to_s
          .gsub('"', "")
          .gsub(/\b3D printable model\b/i, "")
          .gsub(/\bSTL\b/i, "")
          .gsub(/\s+/, " ")
          .strip
      end

      def search_cults(query:, creator_nick: nil)
        graphql = <<~GRAPHQL
          query SearchCreations(
            $query: String!,
            $limit: Int!,
            $creatorNick: String
          ) {
            creationsSearchBatch(
              query: $query
              creatorNick: $creatorNick
              onlySafe: true
              limit: $limit
            ) {
              total
              results {
                name
                url
                shortUrl
                illustrationImageUrl
                creator {
                  nick
                }
              }
            }
          }
        GRAPHQL

        payload = {
          query: graphql,
          variables: {
            query: query,
            limit: MAX_RESULTS,
            creatorNick: creator_nick
          }
        }

        request = Net::HTTP::Post.new(ENDPOINT)

        request.basic_auth(
          ENV.fetch("CULTS_API_USER"),
          ENV.fetch("CULTS_API_PASSWORD")
        )

        request["Accept"] = "application/json"
        request["Content-Type"] = "application/json"
        request["User-Agent"] = "MakerLibrary3D PreviewEnrichment/1.0"

        request.body = JSON.generate(payload)

        response = Net::HTTP.start(
          ENDPOINT.host,
          ENDPOINT.port,
          use_ssl: true,
          open_timeout: 5,
          read_timeout: 15
        ) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "Cults API HTTP #{response.code}"
        end

        data = JSON.parse(response.body)

        if data["errors"].present?
          raise(
            "Cults GraphQL error: " +
            data["errors"].map { |e| e["message"] }.join("; ")
          )
        end

        results = data.dig(
          "data",
          "creationsSearchBatch",
          "results"
        ) || []

        results.filter_map do |result|
          build_candidate(
            result: result,
            query: query,
            requested_creator: creator_nick
          )
        end
      rescue StandardError => error
        Rails.logger.warn(
          {
            event: "preview_enrichment_cults_query_failed",
            provider: "cults3d",
            model_id: model.id,
            query: query,
            creator_nick: creator_nick,
            error: error.class.name,
            message: error.message
          }.to_json
        )

        []
      end

      def build_candidate(result:, query:, requested_creator:)
        page_url =
          result["url"].presence ||
          result["shortUrl"].presence

        image_url = result["illustrationImageUrl"].presence
        title = result["name"].to_s.strip
        creator = result.dig("creator", "nick").to_s.strip

        return nil if page_url.blank?
        return nil if title.blank?

        Candidate.new(
          provider: "cults3d",
          source_page_url: page_url,
          image_url: image_url,
          title: title,
          creator: creator.presence,
          license: nil,
          confidence: confidence_for(
            title: title,
            creator: creator,
            query: query,
            requested_creator: requested_creator
          ),
          match_method:
            requested_creator.present? ?
              "cults_creator_title_search" :
              "cults_title_search",
          metadata: {
            query: query,
            requested_creator: requested_creator,
            returned_creator: creator.presence,
            short_url: result["shortUrl"]
          }
        )
      end

      def confidence_for(title:, creator:, query:, requested_creator:)
        model_text = normalized(model.name)
        title_text = normalized(title)
        query_text = normalized(query)
        creator_text = normalized(creator)

        score = 35

        if title_text == model_text
          score = 95
        elsif title_text == query_text
          score = 92
        else
          model_words = significant_words(model_text)
          title_words = significant_words(title_text)

          overlap = model_words & title_words

          if model_words.any?
            ratio = overlap.length.to_f / model_words.length
            score += (ratio * 50).round
          end

          if title_text.include?(model_text) ||
             model_text.include?(title_text)
            score += 15
          end
        end

        if requested_creator.present?
          requested = normalized(requested_creator)

          if creator_text == requested
            score += 20
          elsif creator_text.include?(requested) ||
                requested.include?(creator_text)
            score += 15
          end
        elsif creator_hints.any? do |hint|
          creator_text == normalized(hint)
        end
          score += 15
        end

        [[score, 40].max, 99].min
      end

      def creator_hints
        @creator_hints ||= begin
          texts = [
            model.name,
            model.path,
            *model.model_files.map(&:filename)
          ].compact.map(&:to_s)

          texts
            .flat_map { |text| text.scan(/@([A-Za-z0-9_.-]+)/).flatten }
            .map { |value| value.gsub(/\.(stl|3mf|obj)\z/i, "") }
            .map(&:strip)
            .reject(&:blank?)
            .uniq
            .first(3)
        end
      end

      def significant_words(text)
        normalized(text)
          .scan(/[a-z0-9]+/)
          .reject { |word| word.length < 3 }
          .reject do |word|
            %w[
              stl
              model
              printable
              presupported
              supported
              version
              file
              files
            ].include?(word)
          end
          .uniq
      end

      def normalized(value)
        value.to_s
          .downcase
          .gsub(/[^a-z0-9]+/, " ")
          .gsub(/\s+/, " ")
          .strip
      end
    end
  end
end
