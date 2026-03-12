//レトロフィルター
//ピクセレート（モザイク化のようなもの）でアナログ信号をエミュレートしてレトロ感を出すフィルター
//このフィルターの前に、2～3px程のボカシを入れておくと品質を誤魔化せるのでオススメ
//※魚眼レンズフィルターを併用すると効果量が変わる可能性があります
//　ソフト本体の内部仕様の影響であるため、ソフトのアップデートなどで設定が狂う恐れも
//value0でピクセレートの強さを設定	0～適当な値
//value1で色差信号の曖昧さを調整	0～適当な値
//value2でCRT風マスクの強さを調整	0～1
//value3でCRT風マスク画像の大きさを調整	-1～1.0　0.0で640x480のサイズ、-1.0に近づけると荒く、1.0で2倍の1280x960サイズ	現実的なサイズよりちょっと荒いくらいがいいかも

//CRT風ドット表現の解像度
#define	res_w	640.0
#define	res_h	480.0

#define PI	3.14159263589793	//いわずもがな円周率

Texture2D InputTexture : register(t0);
SamplerState InputSampler : register(s0);
cbuffer constants : register(b0)
{
	float time: packoffset(c0.x);
	float duration: packoffset(c0.y);

	float value0 : packoffset(c0.z);
	float value1 : packoffset(c0.w);
	float value2 : packoffset(c1.x);
	float value3 : packoffset(c1.y);

	float left : packoffset(c1.z);
	float top : packoffset(c1.w);
	float right : packoffset(c2.x);
	float bottom : packoffset(c2.y);
};

//YUV色空間への変換、逆変換
float4 RGBtoYUV(float4 RGBA)
{
	float4	yuv;
	yuv.r	= dot( RGBA.rgb, float3( 0.299, 0.587, 0.114 ) );
	yuv.g	= dot( RGBA.rgb, float3( -0.168736, -0.331264, 0.5 ) );
	yuv.b	= dot( RGBA.rgb, float3( 0.5, -0.418688, -0.081312 ) );
	yuv.a	= RGBA.a;
	return yuv;
}
float4 YUVtoRGB(float4 YUV)
{
	float4	rgb;
	float	Y = YUV.r;
	float	U = YUV.g;
	float	V = YUV.b;
	rgb.r	= Y + 1.402 * V;
	rgb.g	= Y - 0.344136 * U - 0.714136 * V;
	rgb.b	= Y + 1.772 * U;
	rgb.a	= YUV.a;
	return max( rgb, 0.0 );
}

//低解像度化ピクセレートのためのUV計算関数
float2	Pixelate( float2 uv, float2 pixel_size_factor ){
	float2	uv_dash	= uv * pixel_size_factor;	//UVをスケーリング
	uv_dash	= floor(uv_dash);	//端数を切り捨てることでピクセレート
	uv_dash	/= pixel_size_factor;	//元の大きさに戻す
	return uv_dash;
}

//CRT風のドット表現
//テクスチャで与えたいが無理なのでプロシージャル
//画面UV座標からCRT風ドットをサンプリングしマスク画像とする
//デフォルトでは640x480を想定し、フラグメントが640x480のドットのどこに存在しているのかを詳細に計算
float4	GenCRTmask( float2 uv ){
	//CRTドットの上の詳細な位置を割り出し
	float2	uv_inCRT	= frac( uv*float2( res_w, res_h ) );
	
	//ドット上での詳細な位置を元にドットの色を生成する
	//水平方向にR,G,Bそして黒を配置
	float4	color;
	color.a = 1.0;
	color.r	= smoothstep( 0.0, 0.2, uv_inCRT.x ) * ( 1.0 - smoothstep( 0.2, 0.4, uv_inCRT.x ) );
	color.g	= smoothstep( 0.3, 0.5, uv_inCRT.x ) * ( 1.0 - smoothstep( 0.5, 0.7, uv_inCRT.x ) );
	color.b	= smoothstep( 0.6, 0.8, uv_inCRT.x ) * ( 1.0 - smoothstep( 0.8, 1.0, uv_inCRT.x ) );
	//垂直方向にも薄っすら境界線が欲しいので一本灰色を乗算
	color.rgb	*= 1.0 - 0.5*smoothstep(  7.0/8.0, 1.0, uv_inCRT.y )*( 1.0 - smoothstep( 0.0, 1.0/8.0, uv_inCRT.y) );
	
	return color;
}

float4 main(float4 pos : SV_POSITION, float4 posScene : SCENE_POSITION, float4 uv : TEXCOORD0) : SV_Target
{
	//スクリーン上のポジション(0～1)
	//uvではタイル化処理の影響でスクリーン上の正確な位置がわからないので、posSceneと矩形データからフラグメントの詳細な位置を割り出す
	float2	screen_pos	= (posScene.xy/float2(right-left,bottom-top)+0.5 );	//多分これで合ってる…と思う　詳細な説明が見つからない
	
	//ユーザー入力によるパラメータ設定
		//ピクセレートサイズに影響する変数
		float	psf_tmp	= 1.0/( pow( max(value0,0.0001)/10.0, 3.0 ) + 0.0001 );
		//色差信号のピクセレート倍率
		float	chroma_scale	= 1.0/pow( 2.0, max(value1,0.0001)*4.0 );
		//CRT風マスクはvalue2で適用度を調整
		float	mask_intensity	= clamp( value2, 0.0, 1.0 );
		//CRT風マスク画像のサイズファクター
		float	CRT_SizeFactor	= 1.0 + clamp( value3, -1.0+0.0001, 1.0 );
	
	//輝度と色差信号を表すピクセルをそれぞれサンプリング
		//YUV信号の輝度成分を計算
		float4 Luma_pix;
		float2	psf	= float2( psf_tmp*0.5, psf_tmp );
		Luma_pix = InputTexture.Sample(InputSampler, Pixelate( uv.xy , psf ) );
			
		//YUV信号の色差成分を計算
		float4 Chroma_pix;
		psf	= float2( psf_tmp, psf_tmp )*chroma_scale;
		Chroma_pix = InputTexture.Sample(InputSampler, Pixelate( uv.xy, psf ) );
	
	//それぞれYUV変換
	Luma_pix = RGBtoYUV( Luma_pix );
	Chroma_pix = RGBtoYUV( Chroma_pix );
	//YとUVを抜き出して合成
	float4	YUVsignal	= float4( Luma_pix.r, Chroma_pix.g, Chroma_pix.b, Luma_pix.a );
	//後のマスク処理の影響で彩度が変化してしまうため補正(YUVのUVベクトルの長さが彩度でもあるのだ　豆知識)
	YUVsignal.gb	*= lerp( 1.0, 1.4, mask_intensity );
	//YUV→RGB変換
	float4	RGBsignal	= YUVtoRGB( YUVsignal );
	
	//CRT風ドットを表現するためのマスクを生成
	float4	mask	= GenCRTmask( screen_pos * CRT_SizeFactor );
	//単純な乗算では暗くなりすぎてしまうので、輝度によってマスクの強さを調整
	//輝度が高い時マスクを弱く、暗い時ほど強くあてる
	mask	= lerp( mask, float4(1,1,1,1), YUVsignal.r );
	RGBsignal	= RGBsignal * lerp( 1.0, mask, mask_intensity );
	//マスクを掛けるとガンマやコントラストが変化してしまう
	//別途補正するのが効率的だが、一応ガンマだけ軽く補正をかけておく(補正値は経験的)
	RGBsignal	= pow( RGBsignal, lerp( 1.0, 0.55, mask_intensity ) );
	
	//インターレース走査線による点滅を再現
	//これも輝度に合わせて効果を変えたほうがいい
	//プログレッシブ表現にしたい・点滅がムカつくのならここはコメントアウトするといいかも
	float	flicker	= sin( 0.5*PI*screen_pos.y*res_h*CRT_SizeFactor + time*90.0 );
	RGBsignal	*= lerp( 1.0+flicker*0.5*mask_intensity, 1.0, YUVsignal.r );
	
	return RGBsignal;
};
