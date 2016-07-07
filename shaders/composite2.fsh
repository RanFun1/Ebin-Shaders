#version 410 compatibility
#define composite2
#define fsh
#define ShaderStage 2
#include "/lib/Syntax.glsl"


/* DRAWBUFFERS:1 */

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D gdepthtex;
uniform sampler2D depthtex1;
uniform sampler2D noisetex;
uniform sampler2DShadow shadow; 

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;

uniform vec3 cameraPosition;

uniform float frameTimeCounter;
uniform float rainStrength;

uniform float viewWidth;
uniform float viewHeight;

uniform float near;
uniform float far;

uniform int isEyeInWater;

varying vec2 texcoord;

#include "/lib/Settings.glsl"
#include "/lib/Utility.glsl"
#include "/lib/DebugSetup.glsl"
#include "/lib/Uniform/GlobalCompositeVariables.glsl"
#include "/lib/Fragment/Masks.fsh"
#include "/lib/Misc/CalculateFogFactor.glsl"
#include "/lib/Fragment/ReflectanceModel.fsh"

const bool colortex3MipmapEnabled = true;


vec3 GetColor(in vec2 coord) {
	return DecodeColor(texture2D(colortex3, coord).rgb);
}

vec3 GetColorLod(in vec2 coord, in float lod) {
	return DecodeColor(texture2DLod(colortex3, coord, lod).rgb);
}

float GetDepth(in vec2 coord) {
	return texture2D(gdepthtex, coord).x;
}

float GetTransparentDepth(in vec2 coord) {
	return texture2D(depthtex1, coord).x;
}

float ExpToLinearDepth(in float depth) {
	return 2.0 * near * (far + near - depth * (far - near));
}

vec4 CalculateViewSpacePosition(in vec2 coord, in float depth) {
	vec4 position  = gbufferProjectionInverse * vec4(vec3(coord, depth) * 2.0 - 1.0, 1.0);
	     position /= position.w;
	
	return position;
}

vec3 ViewSpaceToScreenSpace(vec3 viewSpacePosition) {
	vec4 screenSpace = gbufferProjection * vec4(viewSpacePosition, 1.0);
	
	return (screenSpace.xyz / screenSpace.w) * 0.5 + 0.5;
}

vec3 ViewSpaceToScreenSpace(vec4 viewSpacePosition) {
	vec4 screenSpace = gbufferProjection * viewSpacePosition;
	
	return (screenSpace.xyz / screenSpace.w) * 0.5 + 0.5;
}

vec3 GetNormal(in vec2 coord) {
	return DecodeNormal(texture2D(colortex4, coord).xy);
}

#include "/lib/Misc/DecodeBuffer.fsh"


float GetVolumetricFog(in vec2 coord) {
#ifdef VOLUMETRIC_FOG
	return texture2D(colortex5, coord).a;
#endif
	
	return 1.0;
}

float noise(in vec2 coord) {
    return fract(sin(dot(coord, vec2(12.9898, 4.1414))) * 43758.5453);
}


#include "/lib/Fragment/WaterWaves.fsh"

#include "/lib/Fragment/CalculateShadedFragment.fsh"

#include "/lib/Fragment/Sky.fsh"

bool ComputeRaytracedIntersection(in vec3 startingViewPosition, in vec3 rayDirection, in float firstStepSize, cfloat rayGrowth, cint maxSteps, cint maxRefinements, out vec3 screenSpacePosition, out vec4 viewSpacePosition) {
	vec3 rayStep = rayDirection * firstStepSize;
	vec4 ray = vec4(startingViewPosition + rayStep, 1.0);
	
	screenSpacePosition = ViewSpaceToScreenSpace(ray);
	
	float refinements = 0;
	float refinementCoeff = 1.0;
	
	cbool doRefinements = (maxRefinements > 0);
	
	float maxRayDepth = -(far * 1.6 + 16.0);
	
	for (int i = 0; i < maxSteps; i++) {
		if (any(greaterThan(abs(screenSpacePosition.xyz - 0.5), vec3(0.5))) || ray.z < maxRayDepth)
			return false;
		
		float sampleDepth = GetTransparentDepth(screenSpacePosition.st);
		
		viewSpacePosition = CalculateViewSpacePosition(screenSpacePosition.st, sampleDepth);
		
		float diff = viewSpacePosition.z - ray.z;
		
		if (diff >= 0) {
			if (doRefinements) {
				float error = firstStepSize * pow(rayGrowth, i) * refinementCoeff;
				
				if(diff <= error * 2.0 && refinements <= maxRefinements) {
					ray.xyz -= rayStep * refinementCoeff;
					refinementCoeff = 1.0 / exp2(++refinements);
				} else if (diff <= error * 4.0 && refinements > maxRefinements) {
					screenSpacePosition.z = sampleDepth;
					return true;
				}
			}
			
			else return true;
		}
		
		ray.xyz += rayStep * refinementCoeff;
		
		rayStep *= rayGrowth;
		
		screenSpacePosition = ViewSpaceToScreenSpace(ray);
	}
	
	return false;
}

#include "/lib/Fragment/ReflectionFunctions.fsh"

vec2 GetRefractedCoord(in vec2 coord, in vec4 viewSpacePosition, in vec3 tangentNormal) {
	vec4 screenSpacePosition = gbufferProjection * viewSpacePosition;
	
	float fov = atan(1.0 / gbufferProjection[1].y) * 2.0 / RAD;
	
	cfloat refractAmount = 0.5;
	
	vec2 refraction = tangentNormal.st / fov * 90.0 * refractAmount;
	
	vec2 refractedCoord = screenSpacePosition.st + refraction;
	
	refractedCoord = refractedCoord / screenSpacePosition.w * 0.5 + 0.5;
	
	vec2 pixelSize = 1.0 / vec2(viewWidth, viewHeight);
	vec2 minCoord  = pixelSize;
	vec2 maxCoord  = 1.0 - pixelSize;
	
	refractedCoord = clamp(refractedCoord, minCoord, maxCoord);
	
	return refractedCoord;
}

void DecodeTransparentBuffer(in vec2 coord, out float buffer0r, out float buffer0g) {
	float encode = texture2D(colortex0, coord).b;
	
	vec2 buffer0 = Decode16(encode);
	buffer0r = buffer0.r;
	buffer0g = buffer0.g;
}

mat3 DecodeTBN(in float tbnIndex) {
	tbnIndex = round(mod(tbnIndex * 16.0, 8.0));
	
	vec3 tangent;
	vec3 binormal;
	
	if (tbnIndex == 0.0) {
		tangent  = vec3( 0.0,  0.0,  1.0);
		binormal = -tangent.yzy;
	} else if (tbnIndex == 1.0) {
		tangent  = vec3( 0.0,  0.0,  1.0);
		binormal =  tangent.yzy;
	} else if (tbnIndex == 2.0) {
		tangent  = vec3( 1.0,  0.0,  0.0);
		binormal =  tangent.yxy;
	} else if (tbnIndex == 3.0) {
		tangent  = vec3( 1.0,  0.0,  0.0);
		binormal = -tangent.yxy;
	} else if (tbnIndex == 4.0) {
		tangent  = vec3(-1.0,  0.0,  0.0);
		binormal =  tangent.yyx;
	} else {
		tangent  = vec3( 1.0,  0.0,  0.0);
		binormal = -tangent.yyx;
	}
	
	vec3 normal = cross(tangent, binormal);
	
	return mat3(tangent, binormal, normal);
}


void main() {
	float depth0 = GetDepth(texcoord);
	vec4 viewSpacePosition0 = CalculateViewSpacePosition(texcoord, depth0);
	
	
	if (depth0 >= 1.0) { gl_FragData[0] = vec4(EncodeColor(CalculateSky(viewSpacePosition0, true)), 1.0); exit(); return; }
	
	
	vec3 encode; float torchLightmap, skyLightmap, smoothness; Mask mask;
	DecodeBuffer(texcoord, encode, torchLightmap, skyLightmap, smoothness, mask.materialIDs);
	
	mask = CalculateMasks(mask);
	
	float depth1 = depth0;
	vec4  viewSpacePosition1 = viewSpacePosition0;
	vec2  refractedCoord = texcoord;
	float alpha = 0.0;
	
	vec3 normal;
	vec3 color0;
	vec3 color1;
	
	if (mask.transparent > 0.5) {
		mat3 tbnMatrix = DecodeTBN(texture2D(colortex0, texcoord).r);
		
		vec3 tangentNormal;
		
		if (mask.water > 0.5) tangentNormal.xy = GetWaveNormals(viewSpacePosition0, tbnMatrix[2]);
		else                  tangentNormal.xy = Decode16(texture2D(colortex0, texcoord).g) * 2.0 - 1.0;
		
		tangentNormal.z = sqrt(1.0 - lengthSquared(tangentNormal.xy)); // Solve the equation "length(normal.xyz) = 1.0" for normal.z
		
		normal = normalize((gbufferModelView * vec4(tangentNormal * transpose(tbnMatrix), 0.0)).xyz);
		
		
		refractedCoord = GetRefractedCoord(texcoord, viewSpacePosition0, tangentNormal);
		
		
		DecodeTransparentBuffer(texcoord, skyLightmap, smoothness);
		smoothness = mix(smoothness, 0.85, mask.water);
		
		
		alpha = texture2D(colortex2, refractedCoord).r;
		
		color0 = texture2D(colortex1, refractedCoord).rgb / alpha;
		
		if (any(isnan(color0))) color0 = color1;
		
		color1 = DecodeColor(texture2D(colortex3, refractedCoord).rgb);
		
		
		depth1             = GetTransparentDepth(texcoord);
		viewSpacePosition1 = CalculateViewSpacePosition(texcoord, depth1);
	} else {
		normal = GetNormal(texcoord);
		color0 = DecodeColor(texture2D(colortex3, texcoord).rgb);
		color1 = color0;
	}
	
	
	ComputeReflectedLight(color0, viewSpacePosition0, normal, smoothness, skyLightmap, mask);
	
	
	if (depth1 >= 1.0) color0 = mix(CalculateSky(viewSpacePosition0, true), color0, alpha);
	else if (mask.transparent > 0.5) color0 = mix(color1, color0, alpha);
	
	
	CompositeFog(color0, viewSpacePosition0, GetVolumetricFog(texcoord));
	
	
	gl_FragData[0] = vec4(EncodeColor(color0), 1.0);
	
	exit();
}
