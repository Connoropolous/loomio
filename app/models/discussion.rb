class Discussion < ActiveRecord::Base
  PER_PAGE = 50
  SALIENT_ITEM_KINDS = %w[new_comment new_motion new_vote motion_outcome_created]
  THREAD_ITEM_KINDS = %w[new_comment
                         new_motion
                         new_vote
                         motion_closed
                         motion_closed_by_user
                         motion_edited
                         motion_outcome_created
                         motion_outcome_updated
                         discussion_edited]
  paginates_per PER_PAGE

  include ReadableUnguessableUrls
  include Translatable
  include HasTimeframe

  scope :archived, -> { where('archived_at is not null') }
  scope :published, -> { where(archived_at: nil, is_deleted: false) }

  scope :last_activity_after, -> (time) { where('last_activity_at > ?', time) }
  scope :order_by_latest_activity, -> { order('discussions.last_activity_at DESC') }
  scope :order_by_closing_soon_then_latest_activity, -> { order('motions.closing_at ASC, discussions.last_activity_at DESC') }

  scope :visible_to_public, -> { published.where(private: false) }
  scope :not_visible_to_public, -> { where(private: true) }
  scope :with_motions, -> { where("discussions.id NOT IN (SELECT discussion_id FROM motions WHERE id IS NOT NULL)") }
  scope :without_open_motions, -> { where("discussions.id NOT IN (SELECT discussion_id FROM motions WHERE id IS NOT NULL AND motions.closed_at IS NULL)") }
  scope :with_open_motions, -> { joins(:motions).merge(Motion.voting) }
  scope :joined_to_current_motion, -> { joins('LEFT OUTER JOIN motions ON motions.discussion_id = discussions.id AND motions.closed_at IS NULL') }
  scope :chronologically, -> { order('created_at asc') }

  scope :not_by_helper_bot, -> { where('author_id NOT IN (?)', User.helper_bots.pluck(:id)) }

  validates_presence_of :title, :group, :author, :group_id
  validate :private_is_not_nil
  validates :title, length: { maximum: 150 }
  validates_inclusion_of :uses_markdown, in: [true,false]
  validate :privacy_is_permitted_by_group

  is_translatable on: [:title, :description], load_via: :find_by_key!, id_field: :key
  has_paper_trail only: [:title, :description]

  belongs_to :group
  belongs_to :author, class_name: 'User'
  belongs_to :user, foreign_key: 'author_id'
  has_many :motions, dependent: :destroy
  has_one :current_motion, -> { where('motions.closed_at IS NULL') }, class_name: 'Motion'
  has_one :most_recent_motion, -> { order('motions.created_at DESC') }, class_name: 'Motion'
  has_one :search_vector
  has_many :votes, through: :motions
  has_many :comments, dependent: :destroy
  has_many :comment_likes, through: :comments, source: :comment_votes
  has_many :commenters, -> { uniq }, through: :comments, source: :user
  has_many :webhooks, as: :hookable

  has_many :events, -> { includes :user }, as: :eventable, dependent: :destroy

  has_many :items, -> { includes(:user).where(kind: THREAD_ITEM_KINDS).order('created_at ASC') }, class_name: 'Event'
  has_many :salient_items, -> { includes(:user).where(kind: SALIENT_ITEM_KINDS).order('created_at ASC') }, class_name: 'Event'

  has_many :discussion_readers

  include PgSearch
  pg_search_scope :search, against: [:title, :description],
    using: {tsearch: {dictionary: "english"}}


  scope :search_for, ->(query, user, opts = {}) do
    query = sanitize(query)
     select(:id, :key, :title, :result_group_name, :description, :last_activity_at, :rank, "#{query} as query")
    .select("ts_headline(discussions.description, plainto_tsquery(#{query}), 'ShortWord=0') as blurb")
    .from(SearchVector.search_for(query, user, opts))
    .joins("INNER JOIN discussions on subquery.discussion_id = discussions.id")
    .where('rank > 0')
    .order('rank DESC, last_activity_at DESC')
  end

  delegate :name, to: :group, prefix: :group
  delegate :name, to: :author, prefix: :author
  delegate :users, to: :group, prefix: :group
  delegate :full_name, to: :group, prefix: :group
  delegate :email, to: :author, prefix: :author
  delegate :name_and_email, to: :author, prefix: :author
  delegate :locale, to: :author

  after_create :set_last_activity_at_to_created_at

  define_counter_cache :motions_count do |discussion|
    discussion.motions.count
  end

  update_counter_cache :group, :discussions_count
  update_counter_cache :group, :motions_count

  def published_at
    created_at
  end

  def organisation_id
    group.parent_id || group_id
  end

  def archive!
    return if is_archived?
    self.update_attribute(:archived_at, Time.zone.now)
  end

  def is_archived?
    archived_at.present?
  end

  def closed_motions
    motions.closed
  end

  def last_collaborator
    return nil if originator.nil?
    User.find_by_id(originator.to_i)
  end

  alias_method :current_proposal, :current_motion

  def participants
    participants = group.members.where(id: commenters.pluck(:id))
    participants << author
    participants += motion_authors
    participants.uniq
  end

  def motion_authors
    User.find(motions.pluck(:author_id))
  end

  def motion_can_be_raised?
    current_motion.blank?
  end

  def has_previous_versions?
    (previous_version && previous_version.id)
  end

  def last_versioned_at
    if has_previous_versions?
      previous_version.version.created_at
    else
      created_at
    end
  end

  def delayed_destroy
    self.update_attribute(:is_deleted, true)
    self.delay.destroy
  end

  def thread_item_created!(item)
    if THREAD_ITEM_KINDS.include? item.kind
      self.items_count += 1
      self.last_item_at = item.created_at
    end

    if SALIENT_ITEM_KINDS.include? item.kind
      self.salient_items_count += 1
      self.last_activity_at = item.created_at
    end

    if item.kind == 'new_comment'
      self.comments_count += 1
      self.last_comment_at = item.created_at
    end

    if self.first_sequence_id == 0
      self.first_sequence_id = item.sequence_id
    end

    self.last_sequence_id = item.sequence_id

    save!(validate: false)
  end

  def thread_item_destroyed!(item)
    self.items_count -= 1
    self.salient_items_count -= 1 if SALIENT_ITEM_KINDS.include? item.kind

    if item.sequence_id == first_sequence_id
      self.first_sequence_id = sequence_id_or_0(items.sequenced.first)
    end

    if item.sequence_id == last_sequence_id
      last_item = items.sequenced.last
      self.last_sequence_id = sequence_id_or_0(last_item)
      self.last_item_at = last_item.try(:created_at)
      self.last_activity_at = salient_items.last.try(:created_at) || created_at
    end

    save!(validate: false)

    discussion_readers.
      where('last_read_at <= ?', item.created_at).
      each(&:reset_non_comment_counts!)

    true
  end

  def comment_destroyed!(comment)
    self.comments_count -= 1
    self.last_comment_at = comments.maximum(:created_at)

    save!(validate: false)
    discussion_readers.
      where('last_read_at <= ?', comment.created_at).
      each(&:reset_comment_counts!)
  end

  def public?
    !private
  end

  def inherit_group_privacy!
    if self[:private].nil? and group.present?
      self[:private] = group.discussion_private_default
    end
  end

  private
  def set_last_activity_at_to_created_at
    update_attribute(:last_activity_at, created_at)
  end

  def sequence_id_or_0(item)
    item.try(:sequence_id) || 0
  end

  def private_is_not_nil
    errors.add(:private, "Please select a privacy") if self[:private].nil?
  end

  def privacy_is_permitted_by_group
    return unless group.present?
    if self.public? and group.private_discussions_only?
      errors.add(:private, "must be private in this group")
    end

    if self.private? and group.public_discussions_only?
      errors.add(:private, "must be public in this group")
    end
  end
end
