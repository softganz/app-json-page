import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Service for caching images from page JSON files.
///
/// This service handles:
/// - Storing images in cache when they're loaded from server
/// - Retrieving images from cache first before loading from server
/// - Cleaning up old cache entries
class ImageCacheService {
  /// Singleton instance
  static final ImageCacheService _instance = ImageCacheService._internal();

  /// Factory constructor
  factory ImageCacheService() => _instance;

  /// Internal constructor
  ImageCacheService._internal();

  /// Cache manager instance
  final DefaultCacheManager _cacheManager = DefaultCacheManager();

  /// Get a cached image file for a given image URL.
  ///
  /// If the image is already cached, returns the cached file.
  /// If not cached, downloads and caches it, then returns the cached file.
  ///
  /// Returns the cached file, or null if caching fails.
  Future<File?> getCachedImageFile(String imageUrl) async {
    try {
      // Try to get the file from cache first
      final fileInfo = await _cacheManager.getFileFromCache(imageUrl);

      if (fileInfo != null) {
        // Image is already cached, return the cached file
        return fileInfo.file;
      }

      // Image is not cached, download and cache it
      final downloadedFile = await _cacheManager.downloadFile(imageUrl);

      // Successfully downloaded and cached, return the cached file
      return downloadedFile.file;
    } catch (e) {
      // Log the error and return null
      print('[IMAGE_CACHE_SERVICE] Error caching image $imageUrl: $e');
      return null;
    }
  }

  /// Check if an image is already cached.
  ///
  /// Returns true if the image is cached, false otherwise.
  Future<bool> isImageCached(String imageUrl) async {
    try {
      final fileInfo = await _cacheManager.getFileFromCache(imageUrl);
      return fileInfo != null;
    } catch (e) {
      print(
        '[IMAGE_CACHE_SERVICE] Error checking if image is cached $imageUrl: $e',
      );
      return false;
    }
  }

  /// Clear all cached images.
  ///
  /// This removes all cached images from the cache.
  Future<void> clearCache() async {
    try {
      await _cacheManager.emptyCache();
    } catch (e) {
      print('[IMAGE_CACHE_SERVICE] Error clearing cache: $e');
    }
  }
}
