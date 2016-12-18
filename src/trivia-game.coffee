# Description:
#   Play trivia! Doesn't include questions. Questions should be in the following JSON format:
#   {
#       "answer": "Pizza",
#       "category": "FOOD",
#       "question": "Crust, sauce, and toppings!",
#       "value": "$400"
#   },
#
# Dependencies:
#   cheerio - for questions with hyperlinks
#
# Configuration:
#   None
#
# Commands:
#   !trivia - ask a question
#   !skip - skip the current question
#   !answer <answer> or !a <answer> - provide an answer
#   !hint or !h - take a hint
#   !score <player> - check the score of the player
#   !scores or !score all - check the score of all players
#
# Author:
#   yincrash

Fs = require 'fs'
Path = require 'path'
Cheerio = require 'cheerio'
AnswerChecker = require './answer-checker'
Util = require 'util'


class Timer
  @started = null
  @stopped = null
  @startTime = null
  @stopTime = null

  constructor: () ->
    @reset()

  start: () ->
    if not @started
      @startTime = (new Date).getTime()
      @started = true
      @stopped = false

  stop: () -> 
    if not @stopped
      @stopTime = (new Date).getTime()
      @stopped = true
      @started = false

  elapsed: () ->
    (new Date).getTime() - @startTime

  reset: () ->
    @started = false
    @stopped = true
    @startTime = -1
    @stopTime = -1

class Game
  @currentQ = null
  @hintLength = null
  @timer = null
  @intervalId = null
  @questionTimeoutSeconds = null

  constructor: (@robot) ->
    buffer = Fs.readFileSync(Path.resolve('./res', 'questions.json'))
    @timer = new Timer()
    @intervalId = null
    @questions = JSON.parse buffer
    @questionTimeoutSeconds = 15
    @robot.logger.debug "Initiated trivia game script."

  resetQuestionState: () ->
    @resetInterval()
    @timer.reset()

  getSecondsElapsed: () ->
    Math.floor(@timer.elapsed() / 1000.0)

  resetInterval: ->
    clearInterval(@intervalId) if (@intervalId)
    @intervalId = null

  setQuiz: (quiz) ->
    @questions = quiz['question-ids']

  askQuestion: (resp) ->
    unless @currentQ # set current question
      @resetQuestionState()
      @timer.start()
      _this = this

      @intervalId = setInterval () ->
        seconds = _this.getSecondsElapsed()
        max = _this.questionTimeoutSeconds
        resp.send "#{max - seconds} seconds left"
      , 5000

      setTimeout () ->
        _this.skipQuestion(resp)
      , @questionTimeoutSeconds * 1000

      index = Math.floor(Math.random() * @questions.length)
      @currentQ = @questions[index]
      @hintLength = 1
      @robot.logger.debug "Answer is #{@currentQ.answer}"
      # remove optional portions of answer that are in parens
      @currentQ.validAnswer = @currentQ.answer.replace /\(.*\)/, ""

    $question = Cheerio.load ("<span>" + @currentQ.question + "</span>")
    link = $question('a').attr('href')
    text = $question('span').text()
    resp.send "Answer with !a or !answer\n" +
              "For #{@currentQ.value} in the category of #{@currentQ.category}:\n" +
              "#{text} " +
              if link then " #{link}" else ""

  skipQuestion: (resp) ->
    if @currentQ
      resp.send "The answer is #{@currentQ.answer}."
      @currentQ = null
      @hintLength = null
      @resetQuestionState()
      @askQuestion(resp)
    else
      resp.send "There is no active question!"

  answerQuestion: (resp, guess) ->
    if @currentQ
      checkGuess = guess.toLowerCase()
      # remove html entities (slack's adapter sends & as &amp; now)
      checkGuess = checkGuess.replace /&.{0,}?;/, ""
      # remove all punctuation and spaces, and see if the answer is in the guess.
      checkGuess = checkGuess.replace /[\\'"\.,-\/#!$%\^&\*;:{}=\-_`~()\s]/g, ""
      checkAnswer = @currentQ.validAnswer.toLowerCase().replace /[\\'"\.,-\/#!$%\^&\*;:{}=\-_`~()\s]/g, ""
      checkAnswer = checkAnswer.replace /^(an|the)/g, ""
      if AnswerChecker(checkGuess, checkAnswer)
        resp.reply "YOU ARE CORRECT! The answer is #{@currentQ.answer}"
        name = resp.envelope.user.name.toLowerCase().trim()
        value = @currentQ.value.replace /[^0-9.-]+/g, ""
        @robot.logger.debug "#{name} answered correctly."
        user = resp.envelope.user
        user.triviaScore = user.triviaScore or 0
        user.triviaScore += parseInt value
        resp.reply "Score: #{user.triviaScore}"
        @robot.brain.save()
        @resetQuestionState()
        @currentQ = null
        @hintLength = null
      else
        resp.send "#{guess} is incorrect."
    else
      resp.send "There is no active question!"

  hint: (resp) ->
    if @currentQ
      answer = @currentQ.validAnswer
      hint = answer.substr(0,@hintLength) + answer.substr(@hintLength,(answer.length + @hintLength)).replace(/./g, ".")
      if @hintLength <= answer.length
        @hintLength += 1
      resp.send hint
    else
      resp.send "There is no active question!"

  checkScore: (resp, name) ->
    if name == "all"
      scores = ""
      for user in @robot.brain.usersForFuzzyName ""
        user.triviaScore = user.triviaScore or 0
        scores += "#{user.name} - $#{user.triviaScore}\n"
      resp.send scores
    else
      user = @robot.brain.userForName name
      unless user
        resp.send "There is no score for #{name}"
      else
        user.triviaScore = user.triviaScore or 0
        resp.send "#{user.name} - $#{user.triviaScore}"
    
class ApiClient
  constructor: (@robot) ->
    @baseApiUrl = "#{process.env['PROGRAMMING_TRIVIA_CMS_URL']}/api"
    @questionCreateBody = 'body'
    @questionCreateAnswer = 'answer'
    @questionCreateCategory = 'category'
    @questionCreateValue = '1'
    @authToken = ''
    @username = ''

  help: (resp) ->
    doc = """
    !dev list-quizzes - List all quizzes.
    !dev get-quiz $id_or_name - Get a quiz by name or id.
    !dev create-quiz $name - Create a quiz with 0 questions named `name`.
    !dev delete-quiz $id - Delete a quiz by $id.
    !set-question $param "$value" - Sets bound question's $param ({body|answer|value|category}) to $value.  $value must be quoted.
    !dev add-question-to-quiz $quiz_name - Adds the bound question to quiz name $quiz_name.
    !dev delete-question-quiz $quiz_name $question_id - Removes question where id = $id from quiz with name $quiz_name.
    """
    resp.send(doc)


  apiGet: (path, callback, params = {}) ->
    url = "#{@baseApiUrl}/#{path}/#{params['id'] || ''}"
    console.log('apiGet authToken: ' + @authToken)
    cookie = "#{@authToken};username=#{@username}"

    @robot.http(url)
      .header('cookie', cookie)
      .get() (err, res, body) ->
        callback err, res, body

  apiPost: (path, callback, args) ->
    json = JSON.stringify args
    @robot.http("#{@baseApiUrl}/#{path}")
      .header('Content-Type', 'application/json')
      .post(json) (err, res, body) ->
        callback err , res, body

  addQuestion: (quizName, callback) ->
    json = JSON.stringify(@getCurrentQuestion())

    @robot.http("#{@baseApiUrl}/quizzes/#{quizName}/questions")
      .header('Content-Type', 'application/json')
      .post(json) (err, res, body) ->
        callback err, res, body

  deleteQuestion: (quizName, questionId, callback) ->
    url = "#{@baseApiUrl}/quizzes/#{quizName}/questions/#{questionId}"

    @robot.http(url)
      .del() (err, res, body) ->
        callback err, res, body

  setQuestionCreateBody: (body) ->
    @questionCreateBody = body
    
  setQuestionCreateAnswer: (answer) ->
    @questionCreateAnswer = answer

  setQuestionCreateCategory: (category) ->
    @questionCreateCategory = category

  setQuestionCreateValue: (value) ->
    @questionCreateValue = value

  deleteQuiz: (quizName, callback) ->
    url = "#{@baseApiUrl}/quizzes/#{quizName}"

    @robot.http(url)
      .del() (err, res, body) ->
        callback err, res, body

  getCurrentQuestion: () ->
    {
      "body": @questionCreateBody,
      "answer": @questionCreateAnswer,
      "category": @questionCreateCategory,
      "value": @questionCreateValue
    }

  login: (callback, username, password) ->
    json = JSON.stringify { 'username': username, 'password': password }
    @username = username
    @robot.http("#{process.env['PROGRAMMING_TRIVIA_CMS_URL']}/login")
      .header('Content-Type', 'application/json')
      .post(json) (err, res, body) ->
        callback err , res, body

  logout: (callback) ->
    cookie = "#{@authToken};username=#{@username}"

    @robot.http("#{process.env['PROGRAMMING_TRIVIA_CMS_URL']}/logout")
      .header('cookie', cookie)
      .post() (err, res, body) ->
        callback err, res, body

  dev: (resp, command, args...) ->
    response = ''

    callback = (err, res, body) ->
      if err
        resp.send err
        return err
      resp.send JSON.stringify(res.headers)
      resp.send body
      body

    self = @

    loginCallback = (err, res, body) ->
      if err
        resp.send err
        return err

      headers = res.headers
      resp.send(JSON.stringify(headers))
      setCookie = headers['set-cookie']

      self.authToken = setCookie[0].split(';')[0] unless body != '1'
      resp.send(self.authToken)
      resp.send(body)
      body

    logoutCallback = (err, res, body) ->
      if err
        resp.send err
        return err

      resp.send(body)
      body

    switch command
      when "login" then response = @login loginCallback, args[0], args[1]
      when "logout" then response = @logout logoutCallback
      when "list-quizzes" then response = @apiGet 'quizzes', callback
      when "get-quiz" then response = @apiGet "quizzes/#{args[0]}", callback
      when "create-quiz" then response = @apiPost 'quizzes/create', callback, { "quiz-name": args[0] }
      when "delete-quiz" then response = @deleteQuiz args[0], callback
      when "add-question-to-quiz" then response = @addQuestion args[0], callback
      when "delete-question-from-quiz" then response = @deleteQuestion args[0], args[1], callback
      else resp.send "#{command} not found."

module.exports = (robot) ->
  game = new Game(robot)
  api = new ApiClient(robot)

  robot.hear /^!dev ([A-Za-z-]+) ?([\-_0-9A-Za-z]+)? ?([\-0-9A-Za-z]+)?/, (resp) ->
    api.dev resp, resp.match[1], resp.match[2], resp.match[3]

  robot.hear /^!set-quiz ([0-9A-Za-z-]+)/i, (resp) ->
    quiz = api.dev resp, 'get-quiz', resp.match[1]

    api.apiGet "quizzes/#{resp.match[1]}", (err, res, body) ->
      game.setQuiz(JSON.parse(body))
      if err
        return err
      body

  robot.hear /^!set-question ([a-z]+) ("|“)([\s0-9A-Za-z-]+)"/i, (resp) ->
    command = resp.match[1]
    param = resp.match[3]
    
    switch command
      when "body" then api.setQuestionCreateBody  param
      when "category" then api.setQuestionCreateCategory param
      when "value" then api.setQuestionCreateValue  param
      when "answer" then api.setQuestionCreateAnswer param

    currentQuestion = api.getCurrentQuestion()

    resp.send JSON.stringify(currentQuestion)
    
  robot.hear /^!trivia/, (resp) ->
    game.askQuestion(resp)

  robot.hear /^!skip/, (resp) ->
    game.skipQuestion(resp)

  robot.hear /^!a(nswer)? (.*)/, (resp) ->
    game.answerQuestion(resp, resp.match[2])

  robot.hear /^!score (.*)/i, (resp) ->
    game.checkScore(resp, resp.match[1].toLowerCase().trim())

  robot.hear /^!scores/i, (resp) ->
    game.checkScore(resp, "all")

  robot.hear /^!h(int)?/, (resp) ->
    game.hint(resp)

  robot.hear /^!apihelp/, (resp) ->
    api.help(resp)

module.ApiClient = ApiClient

