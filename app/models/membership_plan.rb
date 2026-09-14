class MembershipPlan < ApplicationRecord
  BILLING_INTERVALS = %w[
    month
    year
    lifetime
    custom
  ].freeze

  has_many :membership_plan_libraries,
    dependent: :destroy

  has_many :libraries,
    through: :membership_plan_libraries

  has_many :users,
    dependent: :nullify

  validates :name,
    presence: true,
    uniqueness: {
      case_sensitive: false
    }

  validates :billing_interval,
    inclusion: {
      in: BILLING_INTERVALS
    }

  scope :enabled, -> {
    where(active: true)
  }

  def grants_library?(library)
    return true if all_libraries?

    library_ids.include?(library.id)
  end
end
