class AdminAuditEvent < ApplicationRecord
  belongs_to :actor,
    class_name: "User",
    optional: true

  validates :actor_name, presence: true
  validates :action, presence: true

  scope :recent, -> { order(created_at: :desc) }

  before_update :prevent_modification
  before_destroy :prevent_modification

  private

  def prevent_modification
    errors.add(
      :base,
      "Audit events are append-only."
    )

    throw :abort
  end
end
