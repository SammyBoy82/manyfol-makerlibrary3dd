class Admin::TaxonomyController < ApplicationController
  before_action :require_administrator!

  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    analyzer =
      Admin::TaxonomyAnalyzer.new

    @summary =
      analyzer.summary

    @untagged_models =
      analyzer
        .untagged_models
        .includes(:library)
        .order(:name)
        .limit(50)

    @uncollected_models =
      analyzer
        .uncollected_models
        .includes(:library)
        .order(:name)
        .limit(50)

    @empty_collections =
      analyzer
        .empty_collections
        .order(:name)
        .limit(100)

    @duplicate_tag_groups =
      analyzer
        .duplicate_tag_groups
        .first(100)

    render layout: "settings"
  end

  private

  def require_administrator!
    raise Pundit::NotAuthorizedError unless current_user&.is_administrator?
  end
end
