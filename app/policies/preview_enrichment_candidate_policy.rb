class PreviewEnrichmentCandidatePolicy < ApplicationPolicy
  def index?
    user&.is_administrator?
  end

  def image?
    user&.is_administrator?
  end

  def approve?
    user&.is_administrator?
  end

  def reject?
    user&.is_administrator?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user&.is_administrator?

      scope.all
    end
  end
end
