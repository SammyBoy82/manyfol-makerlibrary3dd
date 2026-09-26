class ModelView < ApplicationRecord
  belongs_to :user
  belongs_to :model

  validates :last_viewed_at, presence: true
  validates :view_count, numericality: {only_integer: true, greater_than: 0}
  validates :model_id, uniqueness: {scope: :user_id}

  scope :recent_first, -> { order(last_viewed_at: :desc) }

  def self.record!(user:, model:)
    return unless user && model

    record = find_or_initialize_by(user: user, model: model)
    record.last_viewed_at = Time.current
    record.view_count = record.persisted? ? record.view_count.to_i + 1 : 1
    record.save!
    record
  rescue ActiveRecord::RecordNotUnique
    retry
  end
end
