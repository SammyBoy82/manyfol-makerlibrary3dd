class LibraryIngestionControl < ApplicationRecord
  def self.current
    first_or_create!
  end

  def self.paused?
    current.paused?
  end
end
