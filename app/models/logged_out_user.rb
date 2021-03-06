class LoggedOutUser
  include AvatarInitials
  attr_accessor :name, :email, :avatar_initials
  alias :read_attribute_for_serialization :send

  def initialize(name: nil, email: nil)
    @name = name
    @email = email
    set_avatar_initials if (@name || @email)
  end

  NIL_METHODS   = [:id, :key, :username, :avatar_url, :selected_locale, :deactivated_at, :time_zone]
  FALSE_METHODS = [:is_logged_in?, :uses_markdown?, :is_organisation_coordinator?, :belongs_to_manual_subscription_group?,
                   :email_when_proposal_closing_soon, :email_missed_yesterday, :email_when_mentioned, :email_on_participation]
  EMPTY_METHODS = [:groups, :group_ids, :adminable_group_ids]
  TRUE_METHODS  = [:is_logged_out?]

  NIL_METHODS.each   { |method| define_method(method, -> { nil }) }
  FALSE_METHODS.each { |method| define_method(method, -> { false }) }
  EMPTY_METHODS.each { |method| define_method(method, -> { [] }) }
  TRUE_METHODS.each  { |method| define_method(method, -> { true }) }

  def angular_ui_enabled
    false
  end
  alias :angular_ui_enabled? :angular_ui_enabled

  def votes
    Vote.none
  end

  def locale
    I18n.default_locale
  end

  def avatar_url(size)
    nil
  end

  def avatar_kind
    'initials'
  end

  def is_member_of?(group)
    false
  end

  def can?(*args)
    false
  end

  def ability
    @ability ||= Ability.new(self)
  end

end
