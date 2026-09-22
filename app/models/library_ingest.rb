class LibraryIngest < ApplicationRecord
  STATUSES = %w[
    pending
    processing
    completed
    failed
  ].freeze

  SOURCE_TYPES = %w[
    archive
    directory
    file
    upload
  ].freeze

  PROCESSING_STATUSES = %w[
    waiting
    scanning
    rendering
    ready
    failed
  ].freeze

  DUPLICATE_STATUSES = %w[
    unchecked
    unique
    duplicate_same_library
    duplicate_other_library
  ].freeze

  belongs_to :library
  belongs_to :model, optional: true
  belongs_to :model_file, optional: true

  belongs_to :duplicate_model_file,
    class_name: "ModelFile",
    optional: true

  validates :source_path,
    presence: true

  validates :source_fingerprint,
    uniqueness: {
      scope: [:library_id, :source_path]
    },
    allow_nil: true

  validates :source_name,
    presence: true

  validates :status,
    inclusion: {
      in: STATUSES
    }

  validates :source_type,
    inclusion: {
      in: SOURCE_TYPES
    }

  validates :processing_status,
    inclusion: {
      in: PROCESSING_STATUSES
    }

  validates :duplicate_status,
    inclusion: {
      in: DUPLICATE_STATUSES
    }

  scope :recent,
    -> {
      order(created_at: :desc)
    }

  scope :unfinished,
    -> {
      where(
        status: %w[pending processing failed]
      )
    }

  def pending?
    status == "pending"
  end

  def processing?
    status == "processing"
  end

  def completed?
    status == "completed"
  end

  def failed?
    status == "failed"
  end
end
