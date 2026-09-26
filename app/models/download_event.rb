class DownloadEvent < ApplicationRecord
  belongs_to :user
  belongs_to :model
  belongs_to :model_file, optional: true

  validates :downloaded_at, presence: true
  validates :selection, presence: true, length: {maximum: 64}

  scope :recent_first, -> { order(downloaded_at: :desc) }

  def self.record!(user:, model:, model_file: nil, selection: "all")
    return unless user && model

    create!(
      user: user,
      model: model,
      model_file: model_file,
      selection: selection.presence || "all",
      downloaded_at: Time.current
    )
  end
end
