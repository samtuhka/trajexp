$ = require 'jquery'
deparam = require 'jquery-deparam'
P = require 'bluebird'
THREE = require 'three'
{Signal} = require './signal.ls'

{Scene, addGround, addSky} = require './scene.ls'
{addVehicle} = require './vehicle.ls'
{WsController, KeyboardController} = require './controls.ls'
{IdmVehicle, LoopMicrosim, LoopPlotter} = require './microsim.ls'

Keypress = require 'keypress'
dbjs = require 'db.js'

class MicrosimWrapper
	(@phys) ->
	position:~->
		@phys.position.z
	velocity:~->
		@phys.velocity.z

	acceleration:~-> null

	step: ->

NonSteeringControl = (orig) ->
	ctrl = ^^orig
	ctrl.steering = 0
	return ctrl

{Catchthething} = require './catchthething.ls'
{Sessions} = require './datalogger.ls'

loadScene = (opts) ->
	renderer = new THREE.WebGLRenderer antialias: true
	scene = new Scene
	renderer.autoClear = false
	scene.beforeRender.add -> renderer.clear()

	nVehicles = 20
	spacePerVehicle = 20
	traffic = new LoopMicrosim nVehicles*spacePerVehicle
	for i in [1 til nVehicles]
		v = new IdmVehicle do
			a: 4.0
			b: 10.0
			timeHeadway: 1.0
		v.position = i*spacePerVehicle
		traffic.addVehicle v
	scene.beforePhysics.add traffic~step
	scene.traffic = traffic

	#plotter = new LoopPlotter opts.loopContainer, traffic
	#scene.onRender.add plotter~render

	onSizeSignal = new Signal()
	onSizeSignal.size = [opts.container.width(), opts.container.height()]
	onSize = (handler) ->
		onSizeSignal.add handler
		handler ...onSizeSignal.size
	$(window).resize ->
		onSizeSignal.size = [opts.container.width(), opts.container.height()]
		onSizeSignal.dispatch ...onSizeSignal.size
	onSize (w, h) ->
		renderer.setSize w, h
	onSize (w, h) ->
		scene.camera.aspect = w/h
		scene.camera.updateProjectionMatrix()

	visualWorld = scene.visual
	camera = scene.camera
	renderDriving = ->
		renderer.render visualWorld, camera
	#renderCatching = ->
	#	renderer.render catchthething.scene, catchthething.camera

	nullScene = new THREE.Scene
	renderBlank = ->
		renderer.render nullScene, camera
	doRender = renderDriving
	scene.onRender.add (...args) -> doRender ...args

	#scoreHud = $('#scoreHud')
	blinder = $('#blinder')
	onEyesOpened = new Signal
	onEyesClosed = new Signal
	scene.eyesOpen = true
	onEyesOpened.add !-> scene.eyesOpen := true
	onEyesClosed.add !-> scene.eyesOpen := false

	openEyes = ->
		onEyesOpened.dispatch()
		blinder.fadeOut 0.3*1000
	closeEyes = ->
		blinder.fadeIn 0.3*1000, -> onEyesClosed.dispatch()

	opts.container.on "contextmenu", -> return false

	scoreElement = $('#fuelConsumption')
	els =
		instantValue: $ '#instantMoneyValue'
		instantBar: $ '#instantMoneyBar' .prop min: 0, max: 40
		meanValue: $ '#meanMoneyValue'
		meanBar: $ '#meanMoneyBar' .prop min: 0, max: 40
	
	scene.beforeRender.add ->
		s = scene.scoring
		metersPerLiter = scene.scoring.distanceTraveled/scene.scoring.fuelConsumed
		litersPerMeter = 1.0/metersPerLiter
		litersPer100km = litersPerMeter*1000*100

		instMetersPerLiter = scene.playerVehicle.velocity/s.instantConsumption
		instLitersPer100km = (1.0/instMetersPerLiter)*1000*100

		moneyPerMeter = scene.scoring.moneyGathered/scene.scoring.distanceTraveled
		moneyPerHour = scene.scoring.moneyGathered/scene.scoring.scoreTime*60*60
		#scoreElement.text moneyPerHour
		
		instMoneyPerHour = s.moneyRate*60*60
		els.instantBar.val instMoneyPerHour
		els.instantValue.text Math.round instMoneyPerHour
		els.meanBar.val moneyPerHour
		els.meanValue.text moneyPerHour.toFixed 1
		#scoreElement.text "#{Math.round s.moneyRate*60*60*8} / #{Math.round moneyPerHour}"
		#scoreElement.text instLitersPer100km
		#scoreElement.text moneyPerMeter * 100*1000
		#scoreElement.text litersPer100km


	opts.container.append renderer.domElement
	P.resolve addGround scene
	.then -> addSky scene
	.then ->
		if opts.controller?
			WsController.Connect opts.controller
		else
			new KeyboardController
	.then (controls) ->
		controls = NonSteeringControl controls
		controls.change.add (type, value) ->
			return if type != "blinder"
			if value
				closeEyes()
			else
				openEyes()
		scene.playerControls = controls
		addVehicle scene, controls
	.then (player) ->
		#THE PLAYER VELOCITY IS BROKEN SOMEHOW, HENCE THE JERK<><><
		player.eye.add scene.camera
		player.physical.position.x = -2.2

		scene.playerModel = player
		scene.playerVehicle = new MicrosimWrapper player.physical
			..higlight = true
		traffic.addVehicle scene.playerVehicle
		scene.playerModel.onCrash = new Signal
		player.physical.addEventListener "collide", (e) ->
			# TODO: Make sure ground collisions don't happen
			scene.playerModel.onCrash.dispatch e

		scene.scoring =
			scoreTime: 0
			cumulativeThrottle: 0
			fuelConsumed: 0
			instantConsumption: 0
		maximumFuelFlow = 200/60/1000
		constantConsumption = maximumFuelFlow*0.1
		fuelPrice = 1.5
		meterCompensation = 0.44/1000
		score = scene.scoring
		scene.afterPhysics.add (dt) ->
			score.scoreTime += dt
			score.instantConsumption = scene.playerControls.throttle*maximumFuelFlow + constantConsumption
			score.fuelConsumed += score.instantConsumption*dt
			score.distanceTraveled = scene.playerVehicle.position
			score.moneyRate = scene.playerVehicle.velocity*meterCompensation - score.instantConsumption*fuelPrice
			score.moneyGathered = score.distanceTraveled*meterCompensation - score.fuelConsumed*fuelPrice


	.then -> addVehicle scene
	.then (leader) ->
		leader.physical.position.z = scene.playerVehicle.leader.position
		leader.physical.position.x = -2.2
		scene.beforeRender.add (dt) ->
			leader.physical.position.z = scene.playerVehicle.leader.position
			leader.forceModelSync()


	.then ->
		/*screenTarget = new THREE.WebGLRenderTarget 1024, 1024, format: THREE.RGBAFormat
		screenGeo = new THREE.PlaneGeometry 0.2, 0.2
		screenMat = new THREE.MeshBasicMaterial do
			map: screenTarget
			transparent: true
			alpha: 1
			alphaTest: 0.5
			blending: THREE.CustomBlending
		screen = new THREE.Mesh screenGeo, screenMat
			..position.x = 0.4 - 0.175
			..position.y = 1.25
			..position.z = 0.2
			..rotation.y = Math.PI
		scene.playerModel.body.add screen
		scene.beforeRender.add ->
			renderer.render catchthething.scene, catchthething.camera, screenTarget
			renderer.clear()
		*/
		return scene
$ ->
	opts =
		container: $('#drivesim')
		loopContainer: $('#loopviz')
	opts <<< deparam window.location.search.substring 1

	run = (scene) -> new P (accept, reject) ->
		# WOW, really doesn't belong here!
		pluck = (obj, ...keys) ->
			dump = {}
			for key in keys
				dump[key] = obj[key]
			return dump

		dumpVehicle = (v) ->
			pluck v, \position, \velocity, \acceleration

		addEntry = (scene) ->
			scene.logger.write do
				scene: pluck scene, \time, \eyesOpen
				player: dumpVehicle scene.playerVehicle
				leader: dumpVehicle scene.playerVehicle.leader
				controls: pluck scene.playerControls, \throttle, \brake, \steering, \direction
				scoring: scene.scoring


		clock = new THREE.Clock
		tick = ->
			addEntry scene
			dt = clock.getDelta()
			scene.tick dt
			if scene.time > 3*60
				accept scene
				return
			requestAnimationFrame tick
		tick!

	loadScene opts
	.then (scene) -> new P (accept, reject) ->
		# Wait for the traffic to queue up
		while not scene.traffic.isInStandstill()
			scene.traffic.step 1/60
		# Tick couple of times for a smoother
		# start
		for [0 to 10]
			scene.tick 1/60
		$('#startbutton')
		.prop "disabled", false
		.text "Start!"
		.click ->
			startTime = (new Date).toISOString()
			name = $('#sessionName').val()
			$('#drivesim').fadeIn(1000)
			$('#intro').fadeOut(1000)
			Sessions("tbtSessions").then (sessions) ->
				sessions.create do
						date: startTime
						name: name
			.then (logger) ->
				scene.logger = logger
				run(scene).then accept
	.then (scene) ->
		opts.container.fadeOut()
		$('#outro').fadeIn()
