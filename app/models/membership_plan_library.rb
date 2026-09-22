class MembershipPlanLibrary < ApplicationRecord
  belongs_to :membership_plan
  belongs_to :library

  validates :library_id,
    uniqueness: {
      scope: :membership_plan_id
    }
end
