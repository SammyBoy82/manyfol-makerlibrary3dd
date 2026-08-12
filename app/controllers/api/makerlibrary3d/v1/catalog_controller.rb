module Api
  module Makerlibrary3d
    module V1
      class CatalogController < ApplicationController
        protect_from_forgery with: :null_session

        before_action :authorize_catalog_access!

        def index
          skip_policy_scope
          skip_authorization

          payload = Commercial::CatalogExporter.call(base_url: request.base_url)

          response.set_header("Cache-Control", "private, max-age=60")
          render json: payload
        end

        private

        def authorize_catalog_access!
          configured_token = ENV["COMMERCIAL_CATALOG_API_TOKEN"].to_s
          supplied_token = bearer_token

          if configured_token.present? && secure_token_match?(configured_token, supplied_token)
            return
          end

          return if current_user&.is_administrator?

          render json: {error: "unauthorized"}, status: :unauthorized
        end

        def bearer_token
          scheme, token = request.authorization.to_s.split(" ", 2)
          return "" unless scheme&.casecmp("Bearer")&.zero?

          token.to_s
        end

        def secure_token_match?(expected, supplied)
          return false if supplied.blank?
          return false unless expected.bytesize == supplied.bytesize

          ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
        end
      end
    end
  end
end
