package away3d.core.render
{
	import away3d.arcane;
	import away3d.core.managers.RTTBufferManager;
	import away3d.core.managers.Stage3DManager;
	import away3d.core.managers.Stage3DProxy;
	import away3d.core.math.Matrix3DUtils;
	import away3d.core.pool.RenderableBase;
	import away3d.core.traverse.EntityCollector;
	import away3d.core.traverse.ICollector;
	import away3d.debug.Debug;
	import away3d.entities.Camera3D;
	import away3d.filters.Filter3DBase;
	import away3d.lights.DirectionalLight;
	import away3d.lights.LightBase;
	import away3d.lights.PointLight;
	import away3d.lights.shadowmaps.ShadowMapperBase;
	import away3d.materials.MaterialBase;
	import away3d.textures.RectangleRenderTexture;
	import away3d.textures.RenderTexture;

	import flash.display.Stage;
	import flash.display3D.Context3DBlendFactor;
	import flash.display3D.Context3DCompareMode;
	import flash.display3D.textures.Texture;
	import flash.display3D.textures.TextureBase;
	import flash.geom.Matrix3D;
	import flash.geom.Rectangle;
	import flash.geom.Vector3D;

	use namespace arcane;

	/**
	 * The DefaultRenderer class provides the default rendering method. It renders the scene graph objects using the
	 * materials assigned to them.
	 */
	public class DefaultRenderer extends RendererBase implements IRenderer
	{
		public static const FORWARD_LIGHTING:int = 0;
		public static const MOBILE_DEFERRED_LIGHTING:int = 1;
		public static const MRT_DEFERRED_LIGHTING:int = 2;
		private var _lightMode:int = FORWARD_LIGHTING;

		protected var _requireDepthRender:Boolean;

		private static const RTT_PASSES:int = 1;
		private static const SCREEN_PASSES:int = 2;
		private static const ALL_PASSES:int = 3;

		private var _activeMaterial:MaterialBase;
		private var _worldNormalRenderer:WorldNormalRenderer;
		private var _gbufferRenderer:GBufferRenderer;
		private var _distanceRenderer:DepthRenderer;
		private var _depthRenderer:DepthRenderer;
		private var _deferredLighting:Boolean = false;
		private var _skyboxProjection:Matrix3D = new Matrix3D();

		private var _tempSkyboxMatrix:Matrix3D = new Matrix3D();
		private var _skyboxTempVector:Vector3D = new Vector3D();
		private var _renderTargetToScreenCopy:RenderTargetCopy = new RenderTargetCopy();
		protected var filter3DRenderer:Filter3DRenderer;
		protected var sceneDepthTexture:RenderTexture;
		protected var sceneNormalTexture:RenderTexture;

		private var _forceSoftware:Boolean;
		private var _profile:String;

		/**
		 *
		 * @returns {*}
		 */
		public function get filters3d():Vector.<Filter3DBase>
		{
			return filter3DRenderer? filter3DRenderer.filters : null;
		}
		public function set filters3d(value:Vector.<Filter3DBase>):void
		{
			if (value && value.length == 0)
				value = null;

			if (filter3DRenderer && !value) {
				filter3DRenderer.dispose();
				filter3DRenderer = null;
			} else if (!filter3DRenderer && value) {
				filter3DRenderer = new Filter3DRenderer(_stage3DProxy);
				filter3DRenderer.filters = value;
			}

			if (filter3DRenderer) {
				filter3DRenderer.filters = value;
				_requireDepthRender = filter3DRenderer.requireDepthRender;
			} else {
				_requireDepthRender = false;

				if (!_deferredLighting && sceneDepthTexture) {
					sceneDepthTexture.dispose();
					sceneDepthTexture = null;
				}
			}
		}

		/**
		 * Creates a new DefaultRenderer object.
		 * @param antiAlias The amount of anti-aliasing to use.
		 * @param renderMode The render mode to use.
		 */
		public function DefaultRenderer(forceSoftware:Boolean = false, profile:String = "baseline", deferredLighting:Boolean = false)
		{
			super();
			_depthRenderer = new DepthRenderer();
			_worldNormalRenderer = new WorldNormalRenderer();
			_gbufferRenderer = new GBufferRenderer();
			_distanceRenderer = new DepthRenderer(false, true);
			_forceSoftware = forceSoftware;
			_profile = profile;
			this.deferredLighting = deferredLighting;
		}

		override public function init(stage:Stage):void {
			if (!stage3DProxy)
				stage3DProxy = Stage3DManager.getInstance(stage).getFreeStage3DProxy(_forceSoftware, _profile);

			_rttBufferManager = RTTBufferManager.getInstance(_stage3DProxy);

			if (_width == 0)
				width = stage.stageWidth;
			else
				_rttBufferManager.viewWidth = _width;

			if (_height == 0)
				height = stage.stageHeight;
			else
				_rttBufferManager.viewHeight = _height;
		}

		override public function set stage3DProxy(value:Stage3DProxy):void
		{
			super.stage3DProxy = value;
			_gbufferRenderer.stage3DProxy = _worldNormalRenderer.stage3DProxy = _distanceRenderer.stage3DProxy = _depthRenderer.stage3DProxy = value;
		}


		override public function render(entityCollector:ICollector):void {
			super.render(entityCollector);

			if(!_stage3DProxy || !_stage3DProxy.recoverFromDisposal()) {
				_backBufferInvalid = true;
				return;
			}

			if(_backBufferInvalid) {
				updateBackBuffer();
			}

			if(_shareContext) {
				_stage3DProxy.clearDepthBuffer();
			}

			if(filter3DRenderer) {
				textureRatioX = _rttBufferManager.textureRatioX;
				textureRatioY = _rttBufferManager.textureRatioY;
			}else{
				textureRatioX = 1;
				textureRatioY = 1;
			}

			if(_deferredLighting && _lightMode == MRT_DEFERRED_LIGHTING) {
				renderGBuffer(entityCollector as EntityCollector);
			}else{
				if(_deferredLighting || _requireDepthRender) {
					renderSceneDepthToTexture(entityCollector as EntityCollector);
				}

				if(_deferredLighting) {
					renderSceneWorldNormalToTexture(entityCollector as EntityCollector);
				}
			}

			if(_depthPrepass) {
				renderDepthPrepass(entityCollector as EntityCollector);
			}

			if (filter3DRenderer && _stage3DProxy.context3D) {
				renderScene(entityCollector, filter3DRenderer.getMainInputTexture(_stage3DProxy), _rttBufferManager.renderToTextureRect);
				if(filter3DRenderer.requireDepthRender) {
					filter3DRenderer.render(_stage3DProxy, entityCollector.camera, sceneDepthTexture.getTextureForStage3D(_stage3DProxy) as Texture, _shareContext);
				}else{
					filter3DRenderer.render(_stage3DProxy, entityCollector.camera, null, _shareContext);
				}
			} else {
				if (_shareContext)
					renderScene(entityCollector, null, _scissorRect);
				else
					renderScene(entityCollector);
			}
			super.render(entityCollector);

			if(Debug.showGBuffer && _deferredLighting) {
				if(!_renderTargetToScreenCopy) _renderTargetToScreenCopy = new RenderTargetCopy();
				_context3D.setRenderToBackBuffer();
				_context3D.setTextureAt(0,sceneDepthTexture.getTextureForStage3D(_stage3DProxy));
				_context3D.setTextureAt(1,sceneNormalTexture.getTextureForStage3D(_stage3DProxy));
				_renderTargetToScreenCopy.draw(_stage3DProxy,2);
				_stage3DProxy.clearBuffers();
			}

			if(!_shareContext) {
				_stage3DProxy.present();
			}

			_stage3DProxy.bufferClear = false;
		}

		override protected function executeRender(entityCollector:ICollector, target:TextureBase = null, scissorRect:Rectangle = null, surfaceSelector:int = 0):void
		{
			updateShadows(entityCollector);

			// otherwise RTT will interfere with other RTTs
			if (target) {
				drawRenderables(opaqueRenderableHead, entityCollector, RTT_PASSES);
				drawRenderables(blendedRenderableHead, entityCollector, RTT_PASSES);
			}
			super.executeRender(entityCollector, target, scissorRect, surfaceSelector);
		}

		private function updateShadows(collector:ICollector):void
		{
			_depthRenderer.textureRatioX = 1;
			_depthRenderer.textureRatioY = 1;
			var entityCollector:EntityCollector = collector as EntityCollector;
			var dirLights:Vector.<DirectionalLight> = entityCollector.directionalLights;
			var pointLights:Vector.<PointLight> = entityCollector.pointLights;
			var len:uint, i:uint;
			var light:LightBase;
			var shadowMapper:ShadowMapperBase;

			len = dirLights.length;
			for (i = 0; i < len; ++i) {
				light = dirLights[i];
				shadowMapper = light.shadowMapper;
				if (light.castsShadows && (shadowMapper.autoUpdateShadows || shadowMapper._shadowsInvalid))
					shadowMapper.renderDepthMap(_stage3DProxy, entityCollector, _depthRenderer);
			}

			len = pointLights.length;
			for (i = 0; i < len; ++i) {
				light = pointLights[i];
				shadowMapper = light.shadowMapper;
				if (light.castsShadows && (shadowMapper.autoUpdateShadows || shadowMapper._shadowsInvalid))
					shadowMapper.renderDepthMap(_stage3DProxy, entityCollector, _distanceRenderer);
			}
		}

		/**
		 * @inheritDoc
		 */
		override protected function draw(collector:ICollector, target:TextureBase):void
		{
			var entityCollector:EntityCollector = collector as EntityCollector;
			if(!target) {
				collectRenderables(entityCollector);
			}
			_context3D.setBlendFactors(Context3DBlendFactor.ONE, Context3DBlendFactor.ZERO);

			if (entityCollector.skyBox) {
				if (_activeMaterial)
					_activeMaterial.deactivate(_stage3DProxy);
				_activeMaterial = null;

				_context3D.setDepthTest(false, Context3DCompareMode.ALWAYS);
				drawSkyBox(entityCollector);
			}

			_context3D.setDepthTest(true, Context3DCompareMode.LESS_EQUAL);

			var which:int = target? SCREEN_PASSES : ALL_PASSES;
			drawRenderables(opaqueRenderableHead, entityCollector, which);
			drawRenderables(blendedRenderableHead, entityCollector, which);

			_context3D.setDepthTest(false, Context3DCompareMode.LESS_EQUAL);

			if (_activeMaterial)
				_activeMaterial.deactivate(_stage3DProxy);

			_activeMaterial = null;
		}

		/**
		 * Draw the skybox if present.
		 * @param entityCollector The EntityCollector containing all potentially visible information.
		 */
		private function drawSkyBox(entityCollector:EntityCollector):void
		{
			var skyBox:RenderableBase = entityCollector.skyBox;
			var material:MaterialBase = skyBox.material;
			var camera:Camera3D = entityCollector.camera;

			updateSkyBoxProjection(camera);

			material.activatePass(0, _stage3DProxy, camera);
			material.renderPass(0, skyBox, _stage3DProxy, entityCollector, _skyboxProjection);
			material.deactivatePass(0, _stage3DProxy);
		}

		private function updateSkyBoxProjection(camera:Camera3D):void
		{
			_skyboxProjection.copyFrom(_rttViewProjectionMatrix);
			_skyboxProjection.copyRowTo(2, _skyboxTempVector);
			var camPos:Vector3D = camera.scenePosition;
			var cx:Number = _skyboxTempVector.x;
			var cy:Number = _skyboxTempVector.y;
			var cz:Number = _skyboxTempVector.z;
			var length:Number = Math.sqrt(cx*cx + cy*cy + cz*cz);

			_skyboxTempVector.x = 0;
			_skyboxTempVector.y = 0;
			_skyboxTempVector.z = 0;
			_skyboxTempVector.w = 1;
			_tempSkyboxMatrix.copyFrom(camera.sceneTransform);
			_tempSkyboxMatrix.copyColumnFrom(3,_skyboxTempVector);

			_skyboxTempVector.x = 0;
			_skyboxTempVector.y = 0;
			_skyboxTempVector.z = 1;
			_skyboxTempVector.w = 0;

			Matrix3DUtils.transformVector(_tempSkyboxMatrix,_skyboxTempVector, _skyboxTempVector);
			_skyboxTempVector.normalize();

			var angle:Number = Math.acos(_skyboxTempVector.x*(cx/length) + _skyboxTempVector.y*(cy/length) + _skyboxTempVector.z*(cz/length));
			if(Math.abs(angle)>0.000001) {
				return;
			}

			var cw:Number = -(cx*camPos.x + cy*camPos.y + cz*camPos.z + length);
			var signX:Number = cx >= 0? 1 : -1;
			var signY:Number = cy >= 0? 1 : -1;

			var p:Vector3D = _skyboxTempVector;
			p.x = signX;
			p.y = signY;
			p.z = 1;
			p.w = 1;
			_tempSkyboxMatrix.copyFrom(_skyboxProjection);
			_tempSkyboxMatrix.invert();
			var q:Vector3D = Matrix3DUtils.transformVector(_tempSkyboxMatrix,p,Matrix3DUtils.CALCULATION_VECTOR3D);
			_skyboxProjection.copyRowTo(3, p);
			var a:Number = (q.x*p.x + q.y*p.y + q.z*p.z + q.w*p.w)/(cx*q.x + cy*q.y + cz*q.z + cw*q.w);
			_skyboxTempVector.x = cx*a;
			_skyboxTempVector.y = cy*a;
			_skyboxTempVector.z = cz*a;
			_skyboxTempVector.w = cw*a;
			//copy changed near far
			_skyboxProjection.copyRowFrom(2, _skyboxTempVector);
		}

		/**
		 * Draw a list of renderables.
		 * @param renderables The renderables to draw.
		 * @param entityCollector The EntityCollector containing all potentially visible information.
		 */
		private function drawRenderables(renderable:RenderableBase, collector:ICollector, which:int):void
		{
			var entityCollector:EntityCollector = collector as EntityCollector;
			var numPasses:uint;
			var j:uint;
			var camera:Camera3D = entityCollector.camera;
			var renderable2:RenderableBase;

			while (renderable) {
				_activeMaterial = renderable.material;
				_activeMaterial.updateMaterial(_context3D);

				numPasses = _activeMaterial.numPasses;
				j = 0;

				do {
					renderable2 = renderable;

					var rttMask:int = _activeMaterial.passRendersToTexture(j)? 1 : 2;

					if ((rttMask & which) != 0) {
						_activeMaterial.activatePass(j, _stage3DProxy, camera);
						do {
							_activeMaterial.renderPass(j, renderable2, _stage3DProxy, entityCollector, _rttViewProjectionMatrix);
							renderable2 = renderable2.next as RenderableBase;
						} while (renderable2 && renderable2.material == _activeMaterial);
						_activeMaterial.deactivatePass(j, _stage3DProxy);
					} else {
						do
							renderable2 = renderable2.next as RenderableBase;
						while (renderable2 && renderable2.material == _activeMaterial);
					}

				} while (++j < numPasses);

				renderable = renderable2;
			}
		}

		override public function dispose():void {
			super.dispose();
			_depthRenderer.dispose();
			_distanceRenderer.dispose();
			_worldNormalRenderer.dispose();
			_gbufferRenderer.dispose();
			_depthRenderer = null;
			_distanceRenderer = null;
			_worldNormalRenderer = null;
			_gbufferRenderer = null;
		}

		protected function renderDepthPrepass(entityCollector:EntityCollector):void
		{
			_depthRenderer.disableColor = true;

			if (filter3DRenderer) {
				_depthRenderer.textureRatioX = _rttBufferManager.textureRatioX;
				_depthRenderer.textureRatioY = _rttBufferManager.textureRatioY;
				_depthRenderer.renderScene(entityCollector, filter3DRenderer.getMainInputTexture(_stage3DProxy), _rttBufferManager.renderToTextureRect);
			} else {
				_depthRenderer.textureRatioX = 1;
				_depthRenderer.textureRatioY = 1;
				_depthRenderer.renderScene(entityCollector);
			}

			_depthRenderer.disableColor = false;
		}

		/**
		 * Updates the backbuffer dimensions.
		 */
		protected function updateBackBuffer():void
		{
			if(!_stage3DProxy.context3D) return;
			// No reason trying to configure back buffer if there is no context available.
			// Doing this anyway (and relying on _stageGL to cache width/height for
			// context does get available) means usesSoftwareRendering won't be reliable.
			if (!_shareContext) {
				if (_width && _height) {
					_stage3DProxy.configureBackBuffer(_width, _height, _antiAlias);
					_backBufferInvalid = false;
				}
			}
		}

		protected function renderSceneDepthToTexture(entityCollector:EntityCollector):void
		{
			if(!sceneDepthTexture) {
				sceneDepthTexture = new RenderTexture(_rttBufferManager.textureWidth, _rttBufferManager.textureHeight);
			}else{
				sceneDepthTexture.width = _rttBufferManager.textureWidth;
				sceneDepthTexture.height = _rttBufferManager.textureHeight;
			}
			_depthRenderer.textureRatioX = _rttBufferManager.textureRatioX;
			_depthRenderer.textureRatioY = _rttBufferManager.textureRatioY;
			_depthRenderer.renderScene(entityCollector, sceneDepthTexture.getTextureForStage3D(_stage3DProxy), _rttBufferManager.renderToTextureRect);
		}

		protected function renderSceneWorldNormalToTexture(entityCollector:EntityCollector):void {
			if(!sceneNormalTexture) {
				sceneNormalTexture = new RenderTexture(_rttBufferManager.textureWidth, _rttBufferManager.textureHeight);
			}else{
				sceneNormalTexture.width = _rttBufferManager.textureWidth;
				sceneNormalTexture.height = _rttBufferManager.textureHeight;
			}

			_worldNormalRenderer.textureRatioX = _rttBufferManager.textureRatioX;
			_worldNormalRenderer.textureRatioY = _rttBufferManager.textureRatioY;
			_worldNormalRenderer.renderScene(entityCollector, sceneNormalTexture.getTextureForStage3D(_stage3DProxy), _rttBufferManager.renderToTextureRect);
		}

		protected function renderGBuffer(entityCollector:EntityCollector):void {
			if(!sceneDepthTexture) {
				sceneDepthTexture = new RectangleRenderTexture(_rttBufferManager.textureWidth, _rttBufferManager.textureHeight);
			}else{
				sceneDepthTexture.width = _width;
				sceneDepthTexture.height = _height;
			}

			if(!sceneNormalTexture) {
				sceneNormalTexture = new RectangleRenderTexture(_rttBufferManager.textureWidth, _rttBufferManager.textureHeight);
			}else{
				sceneNormalTexture.width = _width;
				sceneNormalTexture.height = _height;
			}

			_context3D.setRenderToTexture(sceneDepthTexture.getTextureForStage3D(_stage3DProxy), true, _antiAlias, 0, 0);
			_context3D.setRenderToTexture(sceneNormalTexture.getTextureForStage3D(_stage3DProxy), true, _antiAlias, 0, 1);

			_gbufferRenderer.textureRatioX = 1;
			_gbufferRenderer.textureRatioY = 1;
			_gbufferRenderer.renderScene(entityCollector);

			_context3D.setRenderToTexture(null, true, _antiAlias, 0, 0);
			_context3D.setRenderToTexture(null, true, _antiAlias, 0, 1);
			_context3D.setRenderToBackBuffer();
		}

		public function get deferredLighting():Boolean {
			return _deferredLighting;
		}

		public function set deferredLighting(value:Boolean):void {
			if(_deferredLighting == value) return;
			_deferredLighting = value;
			if(_deferredLighting && _profile == "standard") {
				_lightMode = MRT_DEFERRED_LIGHTING;
			}else if(deferredLighting) {
				_lightMode = MOBILE_DEFERRED_LIGHTING;
			}else{
				_lightMode = FORWARD_LIGHTING;
			}
		}
	}
}