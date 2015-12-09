describe 'Inbox Page', ->

  inboxHelper = require './helpers/inbox_helper.coffee'

  beforeEach ->
    inboxHelper.load()

  it 'displays unread threads by group', ->
    expect(inboxHelper.firstGroup()).toContain('Dirty Dancing Shoes')
    expect(inboxHelper.firstGroup()).toContain('Starred discussion')
    expect(inboxHelper.lastGroup()).toContain('Point Break')
    expect(inboxHelper.lastGroup()).toContain('Recent discussion')

    expect(inboxHelper.anyThreads()).not.toContain('Muted discussion')
    expect(inboxHelper.anyThreads()).not.toContain('Old discussion')

  it 'can mark all threads in a group as read', ->
    expect(inboxHelper.firstGroup()).toContain('Dirty Dancing Shoes')
    inboxHelper.clickMarkAsRead()
    expect(inboxHelper.firstGroup()).not.toContain('Dirty Dancing Shoes')
