﻿Shader "Unlit/ScreenSpaceAmbientOcclusion"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "black" {}
    }
    CGINCLUDE
    #include "UnityCG.cginc"

    struct appdata
    {
        float4 vertex : POSITION;
        float2 uv : TEXCOORD0;
    };

    struct v2f
    {
        float2 uv : TEXCOORD0;
        float4 vertex : SV_POSITION;
        float3 viewRay : TEXCOORD1;
        float3 worldRay : TEXCOORD2;
    };


    #define MAX_SAMPLE_KERNEL_COUNT 64
    sampler2D _MainTex;
    #ifdef NORMAL_FROM_DEPTH
    sampler2D _CameraDepthTexture;
    #else
    sampler2D _CameraDepthNormalsTexture;
    #endif
    float4 _SampleKernelArray[MAX_SAMPLE_KERNEL_COUNT];
    float _SampleKernelCount;
    float _SampleKeneralRadius;
    float _DepthBias;

    float4 _MainTex_TexelSize;
    float4 _BlurRadius;
    float _BilaterFilterFactor;

    sampler2D _AOTex;
    sampler2D _NoiseTex;
    float4 _NoiseTex_TexelSize;

    float4x4 _Inverse;

    #pragma shader_feature NORMAL_FROM_DEPTH
    // #define NORMAL_FROM_DEPTH;
    #define RANDOM_TBN;
    #define RANDOM_ROTATION;
    #define DEPTH_BIAS;
    #define BILATERAL_FILTER;

    void NormalFromTexture(float2 uv, out float linear01Depth, out float3 viewNormal, float3 worldRay)
    {
        #ifndef NORMAL_FROM_DEPTH
        float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
        //采样获得深度值和法线值
        DecodeDepthNormal(cdn, linear01Depth, viewNormal);
        viewNormal = normalize(viewNormal);
        #else

        linear01Depth = Linear01Depth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv));
        // float d = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
        //
        // #if defined(UNITY_REVERSED_Z)
        // d = 1.0 - d;
        // #endif
        //
        // #if UNITY_UV_STARTS_AT_TOP
        // if (_MainTex_TexelSize.y < 0)
        // uv.y = 1 - uv.y;
        // #endif
        //
        // float4 position_s = float4(uv.x * 2 - 1, uv.y * 2 - 1, d * 2 - 1, 1.0f);
        // // float4 position_v = mul(_Inverse, position_s);
        //
        // float4 position_v = mul(unity_CameraInvProjection, position_s);
        // position_v = position_v / position_v.w;
        // position_v.z *= -1;
        // float3 pos = mul(unity_CameraToWorld, position_v).xyz;

        float3 pos = _WorldSpaceCameraPos + linear01Depth * worldRay;
        
        // float3 pos = position_v.xyz / position_v.w;
        
        viewNormal = cross(ddx(pos), _ProjectionParams.x * ddy(pos));
        
        // viewNormal = cross(ddx(pos), ddy(pos));
        // viewNormal = normalize(mul((float3x3)unity_WorldToCamera, viewNormal));
        viewNormal = normalize(mul(viewNormal, (float3x3)unity_CameraToWorld));
        // viewNormal = normalize(viewNormal);
        viewNormal.z = -viewNormal.z;
        // viewNormal = pos;
        return;
        
        linear01Depth = Linear01Depth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv));
        const float2 offset1 = float2(0.0, _ScreenParams.w - 1);
        const float2 offset2 = float2(_ScreenParams.z - 1, 0.0);
        //采样获得深度值和法线值
        float depth1 =  Linear01Depth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv + offset1));
        float depth2 = Linear01Depth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv + offset2));
        float3 p1 = float3(offset1 * linear01Depth, depth1 - linear01Depth);
        float3 p2 = float3(offset2 * linear01Depth, depth2 - linear01Depth);
        float3 normal = cross(p1, p2);
        normal.z = -normal.z;

        viewNormal = normalize(normal);
        #endif
    }

    float3 GetNormal(float2 uv, float3 worldRay)
    {
        #ifndef NORMAL_FROM_DEPTH
        float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
        return DecodeViewNormalStereo(cdn);
        #else
        float depth;
        float3 viewNormal;

        NormalFromTexture(uv, depth, viewNormal, worldRay);
        return viewNormal;
        #endif
    }

    half CompareNormal(float3 normal1, float3 normal2)
    {
        return smoothstep(_BilaterFilterFactor, 1.0, dot(normal1, normal2));
    }

    v2f vert_ao(appdata v)
    {
        v2f o;
        o.vertex = UnityObjectToClipPos(v.vertex);
        o.uv = v.uv;
        float4 clipPos = float4(v.uv * 2 - 1.0, 1.0, 1.0);
        float4 viewRay = mul(unity_CameraInvProjection, clipPos);
        o.viewRay = viewRay.xyz / viewRay.w;

        float3 worldRay = o.viewRay;
        worldRay.z *= -1;
        worldRay.xyz = mul((float3x3)unity_CameraToWorld, worldRay);
        o.worldRay = worldRay;

        return o;
    }

    //计算AO贴图
    fixed4 frag_ao(v2f i) : SV_Target
    {
        fixed4 col = tex2D(_MainTex, i.uv);

        float linear01Depth;
        float3 viewNormal;

        NormalFromTexture(i.uv, linear01Depth, viewNormal, i.worldRay);
        // return float4(viewNormal, 1);
        float3 viewPos = linear01Depth * i.viewRay;

        //铺平纹理
        float2 noiseScale = float2(_ScreenParams.x * _NoiseTex_TexelSize.x, _ScreenParams.y * _NoiseTex_TexelSize.y);
        float2 noiseUV = i.uv * noiseScale;
        //采样噪声图
        float3 randvec = tex2D(_NoiseTex, noiseUV).xyz;
        #ifdef RANDOM_TBN
        randvec.xy = randvec.xy * 2 - 1;
        #else
        randvec = randvec * 2 - 1;
        #endif

        #ifndef RANDOM_ROTATION
        randvec = float3(1, 0, 0);
        #endif

        #ifdef RANDOM_TBN
        //Gram-Schimidt处理创建正交基
        float3 tangent = normalize(randvec - viewNormal * dot(randvec, viewNormal));
        float3 bitangent = cross(viewNormal, tangent);
        float3x3 TBN = float3x3(tangent, bitangent, viewNormal);
        #endif

        int sampleCount = _SampleKernelCount;

        float oc = 0.0;
        for (int j = 0; j < sampleCount; j++)
        {
            #ifdef RANDOM_TBN
            //1.注意不要把矩阵乘反了，否则得到的结果很黑;CG语言构造矩阵是"行优先"，OpenGL是"列优先"，两者之间是转置的关系,所以请把learnOpenGL中的顺序反过来
            // float3 randomVec = mul(TBN, _SampleKernelArray[i].xyz);
            float3 randomVec = mul(_SampleKernelArray[j].xyz, TBN);
            #else
            //2.
            float3 randomVec = _SampleKernelArray[j].xyz;
            randomVec = reflect(randomVec, randvec);
            ////如果随机点的位置与法线反向，那么将随机方向取反，使之保证在法线半球
            half dirDif = step(0, dot(randomVec, viewNormal));
            randomVec = randomVec * (dirDif * 2 - 1);
            // randomVec = dot(randomVec, viewNormal) < 0 ? -randomVec : randomVec;
            #endif

            float3 randomPos = viewPos + randomVec * _SampleKeneralRadius;
            float4 rclipPos = mul(unity_CameraProjection, float4(randomPos, 1));
            // float3 rclipPos = mul((float3x3)UNITY_MATRIX_P, randomPos);
            float2 rscreenPos = (rclipPos.xy / rclipPos.w) * 0.5 + 0.5;
            // float2 rscreenPos = -(rclipPos.xy / randomPos.z) * 0.5 + 0.5;

            float randomDepth;
            float3 randomNormal;
            NormalFromTexture(rscreenPos, randomDepth, randomNormal, i.worldRay);

            #ifdef DEPTH_BIAS
            randomDepth = randomDepth + _DepthBias * _ProjectionParams.w;
            #endif

            //1.range check & accumulate
            float rangeCheck = smoothstep(
                1, 0, _SampleKeneralRadius / (abs(randomDepth - linear01Depth) * _ProjectionParams.z));

            // oc += (randomDepth >= linear01Depth ? 1.0 : rangeCheck);
            half depthDif = step(linear01Depth, randomDepth);
            oc += depthDif + (1 - depthDif) * rangeCheck;
        }
        oc = oc / sampleCount;

        return fixed4(viewNormal * 0.5 + 0.5, oc);
    }

    v2f vert(appdata v)
    {
        v2f o;
        o.vertex = UnityObjectToClipPos(v.vertex);
        o.uv = v.uv;

        return o;
    }

    //双边滤波（Bilateral Filter）
    fixed4 frag_blur(v2f i) : SV_Target
    {
        float2 delta = _MainTex_TexelSize.xy * _BlurRadius.xy;

        float2 uv = i.uv;
        float2 uv0a = i.uv - delta;
        float2 uv0b = i.uv + delta;
        float2 uv1a = i.uv - 2.0 * delta;
        float2 uv1b = i.uv + 2.0 * delta;
        float2 uv2a = i.uv - 3.0 * delta;
        float2 uv2b = i.uv + 3.0 * delta;

        fixed4 col = tex2D(_MainTex, uv);
        fixed4 col0a = tex2D(_MainTex, uv0a);
        fixed4 col0b = tex2D(_MainTex, uv0b);
        fixed4 col1a = tex2D(_MainTex, uv1a);
        fixed4 col1b = tex2D(_MainTex, uv1b);
        fixed4 col2a = tex2D(_MainTex, uv2a);
        fixed4 col2b = tex2D(_MainTex, uv2b);

        #ifndef BILATERAL_FILTER
        half result;
        result = col.a;
        result += col0a.a;
        result += col0b.a;
        result += col1a.a;
        result += col1b.a;
        result += col2a.a;
        result += col2b.a;

        return fixed4(col.rgb, result / 7);
        #else

        // float3 normal = GetNormal(uv, i.worldRay);
        // float3 normal0a = GetNormal(uv0a, i.worldRay);
        // float3 normal0b = GetNormal(uv0b, i.worldRay);
        // float3 normal1a = GetNormal(uv1a, i.worldRay);
        // float3 normal1b = GetNormal(uv1b, i.worldRay);
        // float3 normal2a = GetNormal(uv2a, i.worldRay);
        // float3 normal2b = GetNormal(uv2b, i.worldRay);

        float3 normal = col.rgb * 2 - 1;
        float3 normal0a = col0a.rgb * 2 - 1;
        float3 normal0b = col0b.rgb * 2 - 1;
        float3 normal1a = col1a.rgb * 2 - 1;
        float3 normal1b = col1b.rgb * 2 - 1;
        float3 normal2a = col2a.rgb * 2 - 1;
        float3 normal2b = col2b.rgb * 2 - 1;

        half w = 0.37004405286;
        half w0a = CompareNormal(normal, normal0a) * 0.31718061674;
        half w0b = CompareNormal(normal, normal0b) * 0.31718061674;
        half w1a = CompareNormal(normal, normal1a) * 0.19823788546;
        half w1b = CompareNormal(normal, normal1b) * 0.19823788546;
        half w2a = CompareNormal(normal, normal2a) * 0.11453744493;
        half w2b = CompareNormal(normal, normal2b) * 0.11453744493;

        half result;
        result = w * col.a;
        result += w0a * col0a.a;
        result += w0b * col0b.a;
        result += w1a * col1a.a;
        result += w1b * col1b.a;
        result += w2a * col2a.a;
        result += w2b * col2b.a;

        result /= w + w0a + w0b + w1a + w1b + w2a + w2b;
        
        return fixed4(col.rgb, result);
        #endif
    }

    //应用AO贴图
    fixed4 frag_composite(v2f i) : SV_Target
    {
        fixed4 ori = tex2D(_MainTex, i.uv);
        fixed4 ao = tex2D(_AOTex, i.uv);
        ori.rgb *= ao.a;
        return ori;
    }

    fixed4 frag_only_ao(v2f i) : SV_Target
    {
        fixed4 ao = tex2D(_AOTex, i.uv);
        
        return ao.a;
    }
    ENDCG

    SubShader
    {

        Cull Off ZWrite Off ZTest Always

        //Pass 0 : Generate AO 
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_ao
            #pragma fragment frag_ao
            ENDCG
        }

        //Pass 1 : Bilateral Filter Blur
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_ao
            #pragma fragment frag_blur
            ENDCG
        }

        //Pass 2 : Composite AO
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_composite
            ENDCG
        }
        
        //Pass 3 : Only AO
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_only_ao
            ENDCG
        }
    }
}