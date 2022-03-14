
#ifndef COMPUTE_SHADER_TILE_HLSL
#define COMPUTE_SHADER_TILE_HLSL

#include "GBuffer.hlsl"
#include "FramebufferFlat.hlsl"
#include "ForwardTileInfo.hlsl"


RWStructuredBuffer<TileInfo> g_TilebufferRW : register(u0);

RWStructuredBuffer<uint2> g_Framebuffer : register(u1);

groupshared uint s_MinZ;
groupshared uint s_MaxZ;

// 当前tile的光照列表
groupshared uint s_TileLightIndices[MAX_LIGHTS];
groupshared uint s_TileNumLights;

// 当前tile中需要逐样本着色的像素列表
// 我们将两个16位x/y坐标编码进一个uint来节省共享内存空间
groupshared uint s_PerSamplePixels[COMPUTE_SHADER_TILE_GROUP_SIZE];
groupshared uint s_NumPerSamplePixels;

//--------------------------------------------------------------------------------------
// 用于写入我们的1D MSAA UAV
void WriteSample(uint2 coords, uint sampleIndex, float4 value)
{
    g_Framebuffer[GetFramebufferSampleAddress(coords, sampleIndex)] = PackRGBA16(value);
}

// 将两个<=16位的坐标值打包进单个uint
uint PackCoords(uint2 coords)
{
    return coords.y << 16 | coords.x;
}
// 将单个uint解包成两个<=16位的坐标值
uint2 UnpackCoords(uint coords)
{
    return uint2(coords & 0xFFFF, coords >> 16);
}


void ConstructFrustum(uint3 groupId, float minZSample, float maxZSample,
                      out float4 frustumPlanes[6])
{
    // 注意：这里可以进行并行归约(parallel reduction)的优化，但由于我们使用了MSAA并
    // 存储了多重采样的像素在共享内存中，逐渐增加的共享内存压力实际上**减小**内核的总
    // 体运行速度。因为即便是在最好的情况下，在目前具有典型分块(tile)大小的的架构上，
    // 并行归约的速度优势也是不大的。
    // 只有少量实际合法样本的像素在其中。
    if (maxZSample >= minZSample)
    {
        InterlockedMin(s_MinZ, asuint(minZSample));
        InterlockedMax(s_MaxZ, asuint(maxZSample));
    }

    GroupMemoryBarrierWithGroupSync();

    float minTileZ = asfloat(s_MinZ);
    float maxTileZ = asfloat(s_MaxZ);
    
    // 注意：下面的计算每个分块都是统一的(例如：不需要每个线程都执行)，但代价低廉。
    // 我们可以只是先为每个分块预计算视锥平面，然后将结果放到一个常量缓冲区中...
    // 只有当投影矩阵改变的时候才需要变化，因为我们是在观察空间执行，
    // 然后我们就只需要计算近/远平面来贴紧我们实际的几何体。
    // 不管怎样，组同步/局部数据共享(Local Data Share, LDS)或全局内存寻找的开销可能和这小段数学一样多，但值得尝试。
    
    // 从[0, 1]中找出缩放/偏移
    float2 tileScale = float2(g_FramebufferDimensions.xy) * rcp(float(2 * COMPUTE_SHADER_TILE_GROUP_DIM));
    float2 tileBias = tileScale - float2(groupId.xy);

    // 计算当前分块视锥体的投影矩阵
    float4 c1 = float4(g_Proj._11 * tileScale.x, 0.0f, tileBias.x, 0.0f);
    float4 c2 = float4(0.0f, -g_Proj._22 * tileScale.y, tileBias.y, 0.0f);
    float4 c4 = float4(0.0f, 0.0f, 1.0f, 0.0f);

    // Gribb/Hartmann法提取视锥体平面
    // 侧面
    frustumPlanes[0] = c4 - c1; // 右裁剪平面 
    frustumPlanes[1] = c4 + c1; // 左裁剪平面
    frustumPlanes[2] = c4 - c2; // 上裁剪平面
    frustumPlanes[3] = c4 + c2; // 下裁剪平面
    // 近/远平面
    frustumPlanes[4] = float4(0.0f, 0.0f, 1.0f, -minTileZ);
    frustumPlanes[5] = float4(0.0f, 0.0f, -1.0f, maxTileZ);
    
    // 标准化视锥体平面(近/远平面已经标准化)
    [unroll]
    for (uint i = 0; i < 4; ++i)
    {
        frustumPlanes[i] *= rcp(length(frustumPlanes[i].xyz));
    }
}



[numthreads(COMPUTE_SHADER_TILE_GROUP_DIM, COMPUTE_SHADER_TILE_GROUP_DIM, 1)]
void ComputeShaderTileDeferredCS(uint3 groupId : SV_GroupID,
                                 uint3 dispatchThreadId : SV_DispatchThreadID,
                                 uint3 groupThreadId : SV_GroupThreadID,
                                 uint groupIndex : SV_GroupIndex
                                 )
{
    // NOTE: This is currently necessary rather than just using SV_GroupIndex to work
    // around a compiler bug on Fermi.
    // uint groupIndex = groupThreadId.y * COMPUTE_SHADER_TILE_GROUP_DIM + groupThreadId.x;
    // 注：费米架构是很久以前的显卡了，这里就直接使用SV_GroupIndex
 
    uint totalLights, dummy;
    g_Light.GetDimensions(totalLights, dummy);

    //
    // 获取表面数据，计算当前分块的视锥体
    //
    
    uint2 globalCoords = dispatchThreadId.xy;
    
    SurfaceData surfaceSamples[MSAA_SAMPLES];
    ComputeSurfaceDataFromGBufferAllSamples(globalCoords, surfaceSamples);
        
    // 寻找所有采样中的Z边界
    float minZSample = g_CameraNearFar.x;
    float maxZSample = g_CameraNearFar.y;
    {
        [unroll]
        for (uint sample = 0; sample < MSAA_SAMPLES; ++sample)
        {
            // 避免对天空盒或其它非法像素着色
            float viewSpaceZ = surfaceSamples[sample].posV.z;
            bool validPixel =
                 viewSpaceZ >= g_CameraNearFar.y &&
                 viewSpaceZ < g_CameraNearFar.x;
            [flatten]
            if (validPixel)
            {
                minZSample = min(minZSample, viewSpaceZ);
                maxZSample = max(maxZSample, viewSpaceZ);
            }
        }
    }
    
    // 初始化共享内存中的光照列表和Z边界
    if (groupIndex == 0)
    {
        s_TileNumLights = 0;
        s_NumPerSamplePixels = 0;
        s_MinZ = 0x7F7FFFFF; // 最大浮点数
        s_MaxZ = 0;
    }

    GroupMemoryBarrierWithGroupSync();
    
    float4 frustumPlanes[6];
    ConstructFrustum(groupId, minZSample, maxZSample, frustumPlanes);
    
    //
    // 对当前分块(tile)进行光照裁剪
    //
    
    // 组内每个线程承担一部分光源的碰撞检测计算
    for (uint lightIndex = groupIndex; lightIndex < totalLights; lightIndex += COMPUTE_SHADER_TILE_GROUP_SIZE)
    {
        PointLight light = g_Light[lightIndex];
                
        // 点光源球体与tile视锥体的碰撞检测
        bool inFrustum = true;
        [unroll]
        for (uint i = 0; i < 6; ++i)
        {
            float d = dot(frustumPlanes[i], float4(light.posV, 1.0f));
            inFrustum = inFrustum && (d >= -light.attenuationEnd);
        }

        [branch]
        if (inFrustum)
        {
            // 将光照追加到列表中
            uint listIndex;
            InterlockedAdd(s_TileNumLights, 1, listIndex);
            s_TileLightIndices[listIndex] = lightIndex;
        }
    }

    GroupMemoryBarrierWithGroupSync();
    
    uint numLights = s_TileNumLights;
    //
    // 只处理在屏幕区域的像素(单个分块可能超出屏幕边缘)
    // 
    if (all(globalCoords < g_FramebufferDimensions.xy))
    {
        [branch]
        if (g_VisualizeLightCount)
        {
            [unroll]
            for (uint sample = 0; sample < MSAA_SAMPLES; ++sample)
            {
                WriteSample(globalCoords, sample, (float(s_TileNumLights) / 255.0f).xxxx);
            }
        }
        else if (numLights > 0)
        {
            bool perSampleShading = RequiresPerSampleShading(surfaceSamples);
            // 逐样本着色可视化
            [branch]
            if (g_VisualizePerSampleShading && perSampleShading)
            {
                [unroll]
                for (uint sample = 0; sample < MSAA_SAMPLES; ++sample)
                {
                    WriteSample(globalCoords, sample, float4(1, 0, 0, 1));
                }
            }
            else
            {
                float3 lit = float3(0.0f, 0.0f, 0.0f);
                for (uint tileLightIndex = 0; tileLightIndex < numLights; ++tileLightIndex)
                {
                    PointLight light = g_Light[s_TileLightIndices[tileLightIndex]];
                    AccumulateColor(surfaceSamples[0], light, lit);
                }

                // 计算样本0的结果
                WriteSample(globalCoords, 0, float4(lit, 1.0f));
                        
                [branch]
                if (perSampleShading)
                {
#if DEFER_PER_SAMPLE
                    // 创建需要进行逐样本着色的像素列表
                    uint listIndex;
                    InterlockedAdd(s_NumPerSamplePixels, 1, listIndex);
                    s_PerSamplePixels[listIndex] = PackCoords(globalCoords);
#else
                    // 对当前像素的其它样本进行着色
                    for (uint sample = 1; sample < MSAA_SAMPLES; ++sample)
                    {
                        float3 litSample = float3(0.0f, 0.0f, 0.0f);
                        for (uint tileLightIndex = 0; tileLightIndex < numLights; ++tileLightIndex)
                        {
                            PointLight light = g_Light[s_TileLightIndices[tileLightIndex]];
                            AccumulateColor(surfaceSamples[sample], light, litSample);
                        }
                        WriteSample(globalCoords, sample, float4(litSample, 1.0f));
                    }
#endif
                }
                else
                {
                    // 否则进行逐像素着色，将样本0的结果也复制到其它样本上
                    [unroll]
                    for (uint sample = 1; sample < MSAA_SAMPLES; ++sample)
                    {
                        WriteSample(globalCoords, sample, float4(lit, 1.0f));
                    }
                }
            }
        }
        else
        {
            // 没有光照的影响，清空所有样本
            [unroll]
            for (uint sample = 0; sample < MSAA_SAMPLES; ++sample)
            {
                WriteSample(globalCoords, sample, float4(0.0f, 0.0f, 0.0f, 0.0f));
            }
        }
    }

#if DEFER_PER_SAMPLE && MSAA_SAMPLES > 1
    GroupMemoryBarrierWithGroupSync();

    // 现在处理那些需要逐样本着色的像素
    // 注意：每个像素需要额外的MSAA_SAMPLES - 1次着色passes
    const uint shadingPassesPerPixel = MSAA_SAMPLES - 1;
    uint globalSamples = s_NumPerSamplePixels * shadingPassesPerPixel;

    for (uint globalSample = groupIndex; globalSample < globalSamples; globalSample += COMPUTE_SHADER_TILE_GROUP_SIZE) {
        uint listIndex = globalSample / shadingPassesPerPixel;
        uint sampleIndex = globalSample % shadingPassesPerPixel + 1;        // 样本0已经被处理过了 

        uint2 sampleCoords = UnpackCoords(s_PerSamplePixels[listIndex]);
        SurfaceData surface = ComputeSurfaceDataFromGBufferSample(sampleCoords, sampleIndex);

        float3 lit = float3(0.0f, 0.0f, 0.0f);
        for (uint tileLightIndex = 0; tileLightIndex < numLights; ++tileLightIndex) {
            PointLight light = g_Light[s_TileLightIndices[tileLightIndex]];
            AccumulateColor(surface, light, lit);
        }
        WriteSample(sampleCoords, sampleIndex, float4(lit, 1.0f));
    }
#endif
}

[numthreads(COMPUTE_SHADER_TILE_GROUP_DIM, COMPUTE_SHADER_TILE_GROUP_DIM, 1)]
void ComputeShaderTileForwardCS(uint3 groupId : SV_GroupID,
                                uint3 dispatchThreadId : SV_DispatchThreadID,
                                uint3 groupThreadId : SV_GroupThreadID,
                                uint groupIndex : SV_GroupIndex
                                )
{
    uint totalLights, dummy;
    g_Light.GetDimensions(totalLights, dummy);
    
    //
    // 获取深度数据，计算当前分块的视锥体
    //
    
    uint2 globalCoords = dispatchThreadId.xy;
    
    // 寻找所有采样中的Z边界
    float minZSample = g_CameraNearFar.x;
    float maxZSample = g_CameraNearFar.y;
    {
        [unroll]
        for (uint sample = 0; sample < MSAA_SAMPLES; ++sample)
        {
            // 这里取的是深度缓冲区的Z值
            float viewSpaceZ = g_GBufferTextures[3].Load(globalCoords, sample);
            float2 screenPixelOffset = float2(2.0f, -2.0f) / g_FramebufferDimensions.xy;
            float2 posNdc = (float2(globalCoords) + 0.5f) * screenPixelOffset.xy + float2(-1.0f, 1.0f);
            viewSpaceZ = ComputePositionViewFromZ(posNdc, viewSpaceZ).z;
            
            // 避免对天空盒或其它非法像素着色
            bool validPixel =
                 viewSpaceZ >= g_CameraNearFar.y &&
                 viewSpaceZ < g_CameraNearFar.x;
            [flatten]
            if (validPixel)
            {
                minZSample = min(minZSample, viewSpaceZ);
                maxZSample = max(maxZSample, viewSpaceZ);
            }
        }
    }
    
    // 初始化共享内存中的光照列表和Z边界
    if (groupIndex == 0)
    {
        s_TileNumLights = 0;
        s_NumPerSamplePixels = 0;
        s_MinZ = 0x7F7FFFFF; // 最大浮点数
        s_MaxZ = 0;
    }

    GroupMemoryBarrierWithGroupSync();
    
    float4 frustumPlanes[6];
    ConstructFrustum(groupId, minZSample, maxZSample, frustumPlanes);
    
    //
    // 对当前分块(tile)进行光照裁剪
    //
    
    // 计算当前tile在光照索引缓冲区中的位置
    uint2 dispatchWidth = (g_FramebufferDimensions.x + COMPUTE_SHADER_TILE_GROUP_DIM - 1) / COMPUTE_SHADER_TILE_GROUP_DIM;
    uint tilebufferIndex = groupId.y * dispatchWidth + groupId.x;
    
    // 组内每个线程承担一部分光源的碰撞检测计算
    [loop]
    for (uint lightIndex = groupIndex; lightIndex < totalLights; lightIndex += COMPUTE_SHADER_TILE_GROUP_SIZE)
    {
        PointLight light = g_Light[lightIndex];
                
        // 点光源球体与tile视锥体的碰撞检测
        bool inFrustum = true;
        [unroll]
        for (uint i = 0; i < 6; ++i)
        {
            float d = dot(frustumPlanes[i], float4(light.posV, 1.0f));
            inFrustum = inFrustum && (d >= -light.attenuationEnd);
        }

        [branch]
        if (inFrustum)
        {
            // 将光照追加到列表中
            uint listIndex;
            InterlockedAdd(s_TileNumLights, 1, listIndex);
            g_TilebufferRW[tilebufferIndex].tileLightIndices[listIndex] = lightIndex;
        }
    }
    
    GroupMemoryBarrierWithGroupSync();
    
    if (groupIndex == 0)
    {
        g_TilebufferRW[tilebufferIndex].tileNumLights = s_TileNumLights;
    }
}

#endif // COMPUTE_SHADER_TILE_HLSL
