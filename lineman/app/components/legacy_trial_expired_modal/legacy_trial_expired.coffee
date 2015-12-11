shownToGroup = {}
angular.module('loomioApp').factory 'LegacyTrialExpiredModal', (ModalService, AppConfig)  ->

  appropriateToShow: (group, user) ->
    !shownToGroup[group.id] and
    AppConfig.chargify? and
    group.hasNoSubscription() and
    user.isAdminOf(group) and
    user.locale == 'en' and
    group.cohortId > 0 and group.cohortId < 5

  showIfAppropriate: (group, user) ->
    return false unless @appropriateToShow(group, user)
    shownToGroup[group.id] = true
    ModalService.open this,
      group: => group
      user: => user

  templateUrl: 'generated/components/legacy_trial_expired_modal/legacy_trial_expired_modal.html'

  controller: ($scope, ChoosePlanModal, ModalService) ->
    $scope.submit = ->
      ModalService.open ChoosePlanModal, group: -> $scope.group
