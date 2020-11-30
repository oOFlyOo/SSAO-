using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[ExecuteInEditMode]
public class ScreenSpaceAmbientOcclusion : MonoBehaviour
{
    private Material ssaoMaterial = null;
    private Camera currentCamera = null;
    private List<Vector4> sampleKernelList = new List<Vector4>();

    public Texture Nosie;//噪声贴图
    //[Range(0, 0.002f)]
    //public float DepthBiasValue = 0.0f;
    [Range(0.010f, 1.0f)]
    public float SampleKernelRadius = 0.16f;
    [Range(4, 64)]
    public int SampleKernelCount = 32;
    //[Range(0.0f, 5.0f)]
    //public float AOStrength = 1.0f;
    [Range(0, 2)]
    public int DownSample = 0;

    [Range(0, 0.1f)] public float DepthBias = 0.1f;

    [Range(1, 4)]
    public int BlurRadius = 2;
    [Range(0, 0.2f)]
    public float BilaterFilterStrength = 0.2f;

    public bool OnlyShowAO = false;
    public bool UseBlur = true;
    public bool NormalFromDepth = false;

    public enum SSAOPassName
    {
        GenerateAO = 0,
        BilateralFilter = 1,
        Composite = 2,
    }

    private void Awake()
    {
        var shader = Shader.Find("Unlit/ScreenSpaceAmbientOcclusion");

        ssaoMaterial = new Material(shader);
        currentCamera = GetComponent<Camera>();
    }

    private void OnEnable()
    {
        currentCamera.depthTextureMode = DepthTextureMode.Depth | DepthTextureMode.DepthNormals;
    }

    private void OnDisable()
    {
        currentCamera.depthTextureMode = DepthTextureMode.None;
    }

    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        GenerateAOSampleKernel();

        if (NormalFromDepth)
        {
            ssaoMaterial.EnableKeyword("NORMAL_FROM_DEPTH");
        }
        else
        {
            ssaoMaterial.DisableKeyword("NORMAL_FROM_DEPTH");
        }
        //把噪声图筛进去
        ssaoMaterial.SetTexture("_NoiseTex", Nosie);
        ssaoMaterial.SetVectorArray("_SampleKernelArray", sampleKernelList.ToArray());
        ssaoMaterial.SetFloat("_SampleKernelCount", sampleKernelList.Count);
        ssaoMaterial.SetFloat("_SampleKeneralRadius", SampleKernelRadius);
        ssaoMaterial.SetFloat("_DepthBias", DepthBias);
        
        // ssaoMaterial.SetMatrix("_Inverse", (currentCamera.projectionMatrix * currentCamera.worldToCameraMatrix).inverse);

        if (OnlyShowAO && !UseBlur)
        {
            Graphics.Blit(source, destination, ssaoMaterial, (int)SSAOPassName.GenerateAO);

            return;
        }

        var aoRT = RenderTexture.GetTemporary(source.width >> DownSample, source.height >> DownSample, 0);
        Graphics.Blit(source, aoRT, ssaoMaterial, (int)SSAOPassName.GenerateAO);
        
        if (UseBlur)
        {
            var blurRT = RenderTexture.GetTemporary(source.width >> DownSample, source.height >> DownSample, 0);
            ssaoMaterial.SetFloat("_BilaterFilterFactor", 1.0f - BilaterFilterStrength);

            ssaoMaterial.SetVector("_BlurRadius", new Vector4(BlurRadius, 0, 0, 0));
            Graphics.Blit(aoRT, blurRT, ssaoMaterial, (int)SSAOPassName.BilateralFilter);

            ssaoMaterial.SetVector("_BlurRadius", new Vector4(0, BlurRadius, 0, 0));
            if (OnlyShowAO)
            {
                Graphics.Blit(blurRT, destination, ssaoMaterial, (int)SSAOPassName.BilateralFilter);
            }
            else
            {
                Graphics.Blit(blurRT, aoRT, ssaoMaterial, (int)SSAOPassName.BilateralFilter);
            }
            
            RenderTexture.ReleaseTemporary(blurRT);
        }

        if (!OnlyShowAO)
        {
            ssaoMaterial.SetTexture("_AOTex", aoRT);
            Graphics.Blit(source, destination, ssaoMaterial, (int)SSAOPassName.Composite);
        }

        RenderTexture.ReleaseTemporary(aoRT);
    }

    private void GenerateAOSampleKernel()
    {
        if (SampleKernelCount == sampleKernelList.Count)
            return;
        sampleKernelList.Clear();
        for (int i = 0; i < SampleKernelCount; i++)
        {
            var vec = new Vector3(Random.Range(-1f, 1f), Random.Range(-1f, 1f), Random.Range(0f, 1f));
            // var vec = new Vector3(Random.Range(-1f, 1f), Random.Range(-1f, 1f), Random.Range(-1f, 1f));
            vec.Normalize();
            var scale = (float)i / SampleKernelCount;
            scale = Mathf.Lerp(0.01f, 1.0f, scale * scale);
            vec *= scale;
            sampleKernelList.Add(vec);
        }
    }

}