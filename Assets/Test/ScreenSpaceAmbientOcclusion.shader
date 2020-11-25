Shader "Unlit/ScreenSpaceAmbientOcclusion"
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
    };


    #define MAX_SAMPLE_KERNEL_COUNT 64
    sampler2D _MainTex;
    sampler2D _CameraDepthNormalsTexture;
    // float _DepthBiasValue;
    float4 _SampleKernelArray[MAX_SAMPLE_KERNEL_COUNT];
    float _SampleKernelCount;
    //float _AOStrength;
    float _SampleKeneralRadius;
    float _DepthBias;

    float4 _MainTex_TexelSize;
    float4 _BlurRadius;
    float _BilaterFilterFactor;

    sampler2D _AOTex;
    sampler2D _NoiseTex;
    float4 _NoiseTex_TexelSize;

    // #define NORMAL_FROM_DEPTH;
    #define RANDOM_TBN;
    #define RANDOM_ROTATION;
    #define DEPTH_BIAS;
    #define BILATERAL_FILTER;

    void NormalFromTexture(float2 uv, out float linear01Depth, out float3 viewNormal)
    {
        float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
        //采样获得深度值和法线值
        DecodeDepthNormal(cdn, linear01Depth, viewNormal);
        viewNormal = normalize(viewNormal);

        #ifndef NORMAL_FROM_DEPTH
        return;
        #else

        // const float offset = 0.001;
        // const float2 offset1 = float2(0.0, offset);
        const float2 offset1 = float2(0.0, _ScreenParams.w - 1);
        // const float2 offset2 = float2(offset, 0.0);
        const float2 offset2 = float2(_ScreenParams.z - 1, 0.0);
        float4 cdn1 = tex2D(_CameraDepthNormalsTexture, uv + offset1);
        float4 cdn2 = tex2D(_CameraDepthNormalsTexture, uv + offset2);
        //采样获得深度值和法线值
        float depth1 = DecodeFloatRG(cdn1.zw);
        float depth2 = DecodeFloatRG(cdn2.zw);
        // float3 p1 = float3(offset1 * (_ProjectionParams.w * 0.001), depth1 - linear01Depth);
        float3 p1 = float3(offset1 * depth1, depth1 - linear01Depth);
        // float3 p2 = float3(offset2 * (_ProjectionParams.w * 0.001), depth2 - linear01Depth);
        float3 p2 = float3(offset2 * depth2, depth2 - linear01Depth);
        float3 normal = cross(p1, p2);
        normal.z = -normal.z;

        viewNormal = normalize(normal);
        #endif
    }

    float3 GetNormal(float2 uv)
    {
        #ifndef NORMAL_FROM_DEPTH
        float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
        return DecodeViewNormalStereo(cdn);
        #else
        float depth;
        float3 viewNormal;
        
        NormalFromTexture(uv, depth, viewNormal);
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
        return o;
    }

    //计算AO贴图
    fixed4 frag_ao(v2f i) : SV_Target
    {
        fixed4 col = tex2D(_MainTex, i.uv);

        float linear01Depth;
        float3 viewNormal;

        NormalFromTexture(i.uv, linear01Depth, viewNormal);
        // return float4(viewNormal, 1);
        float3 viewPos = linear01Depth * i.viewRay;

        //铺平纹理
        float2 noiseScale = float2(_ScreenParams.x * _NoiseTex_TexelSize.x, _ScreenParams.y * _NoiseTex_TexelSize.y);
        float2 noiseUV = i.uv * noiseScale;
        //采样噪声图
        float3 randvec = tex2D(_NoiseTex, noiseUV).xyz;
        randvec.xy = randvec.xy * 2 - 1;

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
        for (int i = 0; i < sampleCount; i++)
        {
            #ifdef RANDOM_TBN
            //1.注意不要把矩阵乘反了，否则得到的结果很黑;CG语言构造矩阵是"行优先"，OpenGL是"列优先"，两者之间是转置的关系,所以请把learnOpenGL中的顺序反过来
            // float3 randomVec = mul(TBN, _SampleKernelArray[i].xyz);
            float3 randomVec = mul(_SampleKernelArray[i].xyz, TBN);
            #else
            //2.
            float3 randomVec = _SampleKernelArray[i].xyz;
            randomVec = reflect(randomVec, randvec);
            ////如果随机点的位置与法线反向，那么将随机方向取反，使之保证在法线半球
            randomVec = dot(randomVec, viewNormal) < 0 ? -randomVec : randomVec;
            #endif

            float3 randomPos = viewPos + randomVec * _SampleKeneralRadius;
            float3 rclipPos = mul((float3x3)unity_CameraProjection, randomPos);
            // float3 rclipPos = mul((float3x3)UNITY_MATRIX_P, randomPos);
            float2 rscreenPos = (rclipPos.xy / rclipPos.z) * 0.5 + 0.5;
            // float2 rscreenPos = -(rclipPos.xy / randomPos.z) * 0.5 + 0.5;

            float randomDepth;
            float3 randomNormal;
            NormalFromTexture(rscreenPos, randomDepth, randomNormal);

            #ifdef DEPTH_BIAS
            randomDepth = randomDepth + _DepthBias * _ProjectionParams.w;
            #endif

            //1.range check & accumulate
            float rangeCheck = smoothstep(1, 0, _SampleKeneralRadius / (abs(randomDepth - linear01Depth) * _ProjectionParams.z));
            // float rangeCheck = smoothstep(0.0, 1.0, _SampleKeneralRadius / abs(randomDepth - linear01Depth));

            oc += (randomDepth >= linear01Depth ? 1.0 : rangeCheck);
            // oc += (randomDepth >= linear01Depth ? 1.0 : 0.0) * rangeCheck;
        }
        oc = oc / sampleCount;

        col.rgb = oc;
        return col;
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
        half4 result;
        result = col;
        result += col0a;
        result += col0b;
        result += col1a;
        result += col1b;
        result += col2a;
        result += col2b;

        return result / 7;
        #else

        float3 normal = GetNormal(uv);
        float3 normal0a = GetNormal(uv0a);
        float3 normal0b = GetNormal(uv0b);
        float3 normal1a = GetNormal(uv1a);
        float3 normal1b = GetNormal(uv1b);
        float3 normal2a = GetNormal(uv2a);
        float3 normal2b = GetNormal(uv2b);

        half w = 0.37004405286;
        half w0a = CompareNormal(normal, normal0a) * 0.31718061674;
        half w0b = CompareNormal(normal, normal0b) * 0.31718061674;
        half w1a = CompareNormal(normal, normal1a) * 0.19823788546;
        half w1b = CompareNormal(normal, normal1b) * 0.19823788546;
        half w2a = CompareNormal(normal, normal2a) * 0.11453744493;
        half w2b = CompareNormal(normal, normal2b) * 0.11453744493;

        half3 result;
        result = w * col.rgb;
        result += w0a * col0a.rgb;
        result += w0b * col0b.rgb;
        result += w1a * col1a.rgb;
        result += w1b * col1b.rgb;
        result += w2a * col2a.rgb;
        result += w2b * col2b.rgb;

        result /= w + w0a + w0b + w1a + w1b + w2a + w2b;
        return fixed4(result, 1.0);
        #endif
    }

    //应用AO贴图
    fixed4 frag_composite(v2f i) : SV_Target
    {
        fixed4 ori = tex2D(_MainTex, i.uv);
        fixed4 ao = tex2D(_AOTex, i.uv);
        ori.rgb *= ao.r;
        return ori;
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
            #pragma vertex vert
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

    }
}