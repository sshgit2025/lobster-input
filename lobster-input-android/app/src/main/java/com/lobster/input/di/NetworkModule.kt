package com.lobster.input.di

import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.lobster.input.LobsterInputApp
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.core.network.ApiService
import com.lobster.input.data.local.AuthSession
import com.lobster.input.data.model.ApiErrorResponse
import com.lobster.input.data.model.ApiException
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Response
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {
    
    @Provides
    @Singleton
    fun provideGson(): Gson {
        return GsonBuilder()
            .setLenient()
            .create()
    }
    
    @Provides
    @Singleton
    fun provideLoggingInterceptor(): HttpLoggingInterceptor {
        return HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BODY
        }
    }

    @Provides
    @Singleton
    fun provideClientPlatformInterceptor(): Interceptor {
        return Interceptor { chain ->
            val context = LobsterInputApp.instance
            val language = MobileStrings.currentLanguage(context).code
            val request = chain.request().newBuilder()
                .header("X-Client-Platform", ApiConfig.CLIENT_PLATFORM)
                .header("X-Accept-Language", language)
                .build()
            chain.proceed(request)
        }
    }
    
    @Provides
    @Singleton
    fun provideOkHttpClient(
        clientPlatformInterceptor: Interceptor,
        loggingInterceptor: HttpLoggingInterceptor
    ): OkHttpClient {
        return OkHttpClient.Builder()
            .connectTimeout(ApiConfig.CONNECT_TIMEOUT, TimeUnit.SECONDS)
            .readTimeout(ApiConfig.READ_TIMEOUT, TimeUnit.SECONDS)
            .writeTimeout(ApiConfig.WRITE_TIMEOUT, TimeUnit.SECONDS)
            .addInterceptor(clientPlatformInterceptor)
            .addInterceptor(loggingInterceptor)
            .build()
    }
    
    @Provides
    @Singleton
    fun provideRetrofit(
        okHttpClient: OkHttpClient,
        gson: Gson
    ): Retrofit {
        return Retrofit.Builder()
            .baseUrl(ApiConfig.BASE_URL)
            .client(okHttpClient)
            .addConverterFactory(GsonConverterFactory.create(gson))
            .build()
    }
    
    @Provides
    @Singleton
    fun provideApiService(retrofit: Retrofit): ApiService {
        return retrofit.create(ApiService::class.java)
    }
}

// 扩展函数：处理API响应。authHeader 用于避免旧请求返回 401 时清掉新登录态。
suspend fun <T> Response<T>.handleResponse(authHeader: String? = null): T {
    if (isSuccessful) {
        return body() ?: throw ApiException.DecodingError(
            Exception("Response body is null")
        )
    }
    
    val errorBody = errorBody()?.string()
    val errorResponse = try {
        Gson().fromJson(errorBody, ApiErrorResponse::class.java)
    } catch (e: Exception) {
        null
    }
    
    when (code()) {
        401 -> {
            AuthSession.clearIfCurrent(LobsterInputApp.instance, authHeader)
            throw ApiException.Unauthorized
        }
        403 -> {
            if (errorResponse?.code == "USER_BANNED") {
                AuthSession.clearIfCurrent(LobsterInputApp.instance, authHeader)
                throw ApiException.UserBanned
            }
            throw ApiException.HttpError(code(), errorResponse)
        }
        else -> throw ApiException.HttpError(code(), errorResponse)
    }
}
